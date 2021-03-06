%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2012 Max Lapshin
%%% @doc        License client
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlmedia is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlmedia is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlmedia.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(license_client).
-author('Max Lapshin <max@maxidoors.ru>').

-include_lib("kernel/include/file.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("log.hrl").

-define(TIMEOUT, 20*60000).
-define(LICENSE_TABLE, license_storage).

%% External API
-export([load/0]).
-compile(export_all).


-export([license_to_key/1]).

unhex([]) -> <<>>;
unhex([C1,C2|S]) ->
  I1 = from_hex(C1),
  I2 = from_hex(C2),
  <<(I1*16 + I2), (unhex(S))/binary>>.

from_hex(C) when C >= $0 andalso C =< $9 -> C - $0;
from_hex(C) when C >= $a andalso C =< $f -> C - $a + 16#a;
from_hex(C) when C >= $A andalso C =< $F -> C - $A + 16#A.

license_to_key(License) ->
  Key = unhex(re:replace(License, "\\-", "", [{return,list},global])),
  Key.
  


% Логика работы на старте такая:
% 1. ищем файл с конфигом лицензии
% 2. обращаемся к серверу лицензий с ключом и нашим идентификатором
% 3. получаем бимы оттуда
% 4. сверяем их версии с текущими и загружаем их оттуда в память


append_current_version(Commands) ->
  lists:map(fun({project, Project}) ->
    Name = proplists:get_value(name, Project),
    case application:get_key(Name, vsn) of
      {ok, Version} when is_binary(Version) ->
        {project, [{current_version, Version}|Project]};
      {ok, Version} when is_list(Version) ->
        {project, [{current_version, list_to_binary(Version)}|Project]};
      undefined ->
        {project, Project}
    end  
  end, Commands). 
  
%%-------------------------------------------------------------------------
%% @spec () -> ok | {error, Reason}
%% @doc Loads code from storage or from server
%% @end
%% @private
%%-------------------------------------------------------------------------

load() ->
  AllCodeIsLoaded = code:is_loaded(hls),
  case AllCodeIsLoaded of
    {file, _} ->
      error_logger:info_msg("Flussonic is booting in full-bundled mode~n"),
      {ok, []};
    false ->  
      case get_license_key() of
        undefined ->
          error_logger:error_msg("Can't find license key for flussonic. Booting in non-licensed mode~n"),
          {error, no_license_key};
        LicenseKey ->
          load_licensed_code(LicenseKey)
      end
  end.  


get_license_key() ->
  case file:path_open(["priv", "/etc/flussonic", "/etc/erlyvideo"], "license.txt", [read]) of
    {ok, F, ConfigPath} ->
      file:close(F),
      {ok, Data} = file:read_file(ConfigPath),
      case re:run(Data, "^([a-f0-9\\-]+)", [{capture,all_but_first,list}]) of
        nomatch ->
          % Файл лицензии в старом erlang-формате
          case file:consult(ConfigPath) of
            {ok, Env} ->
              proplists:get_value(license, Env);
            {error, Error} ->
              error_logger:error_msg("Failed to load license key because of broken file ~s: ~p", [ConfigPath, Error]),
              undefined
          end;
        {match, [Key]} ->
          % Лицензия лежит в виде ключа в файле
          Key
      end;
    {error, enoent} ->
      undefined
  end.
  
  
load_licensed_code(LicenseKey) ->
  case load_code_from_disk(LicenseKey) of
    undefined ->
      load_code_from_server(LicenseKey);
    Else ->
      Else
  end.


load_code_from_disk(LicenseKey) ->
  Version = case os:getenv("FLUVER") of
    false -> flu:version();
    Ver -> Ver
  end,
  Filename = "licensed_content-"++Version++".pack",
  case file:path_open([".", "/etc/flussonic", "/opt/flussonic"], Filename, [read]) of
    {ok, IO, FullName} ->
      error_logger:info_msg("Loading licensed code from ~s~n", [FullName]),
      file:close(IO),
      {ok, Cypher} = file:read_file(FullName),
      Bin = crypto:aes_ctr_decrypt(license_to_key(LicenseKey), <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>, Cypher),
      {ok, Commands} = unpack_server_response(Bin),
      load_code(Commands);
    {error, _} ->
      undefined
  end.


%%%% load_from_server
%%%%
load_code_from_server(LicenseKey) ->
  case construct_url(LicenseKey) of
    {error,Reason} -> 
      {error,Reason};
    undefined -> 
      {error, no_license};
    URL -> 
      {ok, Commands} = load_by_url(URL),
      load_code(Commands)
  end.

load_by_url(URL) ->
  error_logger:info_msg("License request: ~p~n", [URL]),
  case http_stream:request_body(URL,[{timeout,30000}]) of
    {ok, {Socket, Code, _Headers, Bin}} when Code == 200 orelse Code == 302 ->
      error_logger:info_msg("Loading licensed code~n"),
      gen_tcp:close(Socket),
      unpack_server_response(Bin);
    {ok, {Socket, 404, _Headers, Bin}} ->
      gen_tcp:close(Socket),
      error_logger:error_msg("No selected versions on server: ~p~n", [erlang:binary_to_term(Bin)]),
      {error, notfound};
    {error, Reason} ->
      {error, Reason};
    Else ->
      {error, Else}
  end.
  

unpack_server_response(Bin) ->
  case erlang:binary_to_term(Bin) of
    {reply, Reply} ->
      case proplists:get_value(version, Reply) of
        1 ->
          Commands = proplists:get_value(commands, Reply),
          {ok, Commands};
        Version ->
          {error,{unknown_license_version, Version}}
      end;
    {error, Reason} ->
      error_logger:error_msg("Couldn't load license key: ~p~n", [Reason]),
      {error, Reason}
  end.

construct_url(LicenseKey) when is_binary(LicenseKey) ->
  construct_url(binary_to_list(LicenseKey));

construct_url(LicenseKey) when is_list(LicenseKey) ->
  Version = case os:getenv("FLUVER") of
    false -> "?version="++flu:version();
    Ver -> "?version="++Ver
  end,
  LicenseURL = "http://erlyvideo.org/temp_key/flussonic/"++LicenseKey ++ Version,

  case http_stream:request_body(LicenseURL,[{noredirect, true},{keepalive,false}]) of
	  {ok,{_Socket,Code,_Headers,URL}} when Code == 200 orelse Code == 302 ->
	    save_temp_url(URL),
	    URL;
    {ok,{_Socket,403,_Headers,_Body}} ->
      error_logger:error_msg("License server rejected your key ~s: ~p",[LicenseKey, _Body]),
      undefined;
    {ok,{_Socket,Code,_Headers,_Body}} ->
      error_logger:error_msg("License server don't know about key ~s: ~p ~p",[LicenseKey, Code, _Body]),
      undefined;
	  _Error ->
	    find_cached_temp_url()
	end.

find_cached_temp_url() ->
  in_opened_storage_do(fun(Table) ->
    proplists:get_value(s3_url,dets:lookup(Table,s3_url),{error,url_notfound})
  end).

save_temp_url(URL) ->
  in_opened_storage_do(fun(Table) ->
    dets:insert(Table,[{s3_url,URL}])
  end).  
  
in_opened_storage_do(F) ->
  case dets:open_file(?LICENSE_TABLE,[{file,"license_storage.db"}]) of
	  {ok,?LICENSE_TABLE} ->
	    Result = F(?LICENSE_TABLE),
	    dets:close(?LICENSE_TABLE),
	    Result;
	  Error ->
      Error
  end.



  


get_versions_from_storage() ->
  case dets:lookup(?LICENSE_TABLE,projects) of
    [{projects, Projects}] -> Projects;
    _ -> []
  end.    

versions_of_projects(Config) ->
  case proplists:get_value(projects,Config,undefined) of
    undefined -> in_opened_storage_do(fun(_Table) -> get_versions_from_storage() end);
    Projects -> Projects
  end.
         
%%%% load code
%%%%

load_code(Commands) ->
  case execute_commands_v1(Commands,[]) of
    {ok,Startup} ->
      handle_loaded_modules_v1(Startup),
      Startup;
    Error ->
      Error
  end.
  
execute_commands_v1([], Startup) -> 
  {ok,Startup};

execute_commands_v1([{purge,Module}|Commands], Startup) ->
  case erlang:function_exported(Module, ems_client_unload, 0) of
    true -> (catch Module:ems_client_unload());
    false -> ok
  end,
  case code:is_loaded(Module) of
    true -> error_logger:info_msg("Licence purge ~p", [Module]), code:purge(Module);
    false -> ok
  end,
  execute_commands_v1(Commands, Startup);

execute_commands_v1([{load_app, {application,Name,Desc} = AppDescr}|Commands], Startup)  ->
  Version = proplists:get_value(vsn, Desc),
  case application:load(AppDescr) of
    ok -> error_logger:info_msg("License load application ~p(~p)~n", [Name, Version]);
    {error, {already_loaded, AppDescr}} -> error_logger:info_msg("License already loaded application ~p(~p)", [Name, Version]);
    _Else -> error_logger:error_msg("License failed to load application: ~p", [_Else]), ok
  end,
  execute_commands_v1(Commands, Startup);
    
execute_commands_v1([{load,ModInfo}|Commands], Startup) ->
  Code = proplists:get_value(code, ModInfo),
  {ok, {Module, [Version]}} = beam_lib:version(Code),
  case is_new_version(ModInfo) of
    false -> 
      execute_commands_v1(Commands, Startup);
    true -> 
      error_logger:info_msg("Licence load ~p(~p)", [Module, Version]),
      code:soft_purge(Module),
      code:load_binary(Module, "license/"++atom_to_list(Module)++".erl", Code),
      execute_commands_v1(Commands, [Module|Startup])
  end;

execute_commands_v1([Command|Commands], Startup) when is_tuple(Command) ->
  error_logger:error_msg("Unknown license server command ~p", [Command]),
  execute_commands_v1(Commands, Startup);
  
execute_commands_v1([_Command|Commands], Startup) ->
  error_logger:error_msg("Unknown license server command ~p", [_Command]),
  execute_commands_v1(Commands, Startup).

is_new_version(ModInfo) ->
  Code = proplists:get_value(code, ModInfo),
  {ok, {Module, NewVersion}} = beam_lib:version(Code),
  OldVersion = case code:is_loaded(Module) of
    false -> undefined;
    _ -> proplists:get_value(vsn, Module:module_info(attributes))
  end,
  OldVersion =/= NewVersion.

handle_loaded_modules_v1([]) ->
  ok;

handle_loaded_modules_v1([Module|Startup]) ->
  ems_load_module(Module, before_start),
  handle_loaded_modules_v1(Startup).

ems_load_module(Module, Command) ->
  case erlang:function_exported(Module, ems_client_load, 1) of
    true -> Module:ems_client_load(Command);
    false -> ok
  end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%
%%%%%%   Tests
%%%%%%
%%%%%%  1) run without license.txt at all
%%%%%%  2) run with empty or broken license.txt
%%%%%%  3) proper license.txt with proper load_app reply
%%%%%%  4) proper license.txt with proper save_app reply   
%%%%%%  5) locked version of unavailable project
%%%%%%  6) locked version of available project, when this version isn't available
%%%%%%  7) locked available version of available project
%%%%%%  8) restore proper version from storage
%%%%%%  9) non-restore version from storage if other is selected
%%%%%%  
%%%%%%  
