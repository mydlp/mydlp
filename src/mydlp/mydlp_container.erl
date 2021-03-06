%%%
%%%    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@mydlp.com>
%%%
%%%--------------------------------------------------------------------------
%%%    This file is part of MyDLP.
%%%
%%%    MyDLP is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU General Public License as published by
%%%    the Free Software Foundation, either version 3 of the License, or
%%%    (at your option) any later version.
%%%
%%%    MyDLP is distributed in the hope that it will be useful,
%%%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%    GNU General Public License for more details.
%%%
%%%    You should have received a copy of the GNU General Public License
%%%    along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
%%%--------------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @author H. Kerem Cevahir <kerem@mydlp.com>
%%% @copyright 2011, H. Kerem Cevahir
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------


-module(mydlp_container).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").

%% API
-export([start_link/0,
	schedule_confupdate/0,
	confupdate/0,
	get_ep_meta_dict/0,
	set_general_meta/0,
	get_ep_meta/1,
	set_ep_meta/2,
	set_ep_meta_from_dict/1,
	unset_ep_meta/1,
	get_trap_pid/0,
	set_trap_pid/1,
	reset_trap_pid/0,
	new/0,
	setprop/3,
	getprop/2,
	getpropdict/1,
	push/2,
	pushfile/2,
	pushchunk/2,
	eof/1,
	aclq/1,
	aclq/2,
	getdata/1,
	destroy/1,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(object, {
	buffer=[],
	data,
	size,
	eof_flag=false,
	filepath=undefined,
	prop_dict=dict:new()
	}).

-record(state, {
	confupdate=true,
	ep_meta,  % defined keys are: user , version
	trap_pid,
	object_tree
	}).

-ifdef(__MYDLP_ENDPOINT).

-define(ACLQ_TIMEOUT_MIN, 20000).

-define(ACLQ_TIMEOUT_MAX, 140000).

-define(ACLQ_TIMEOUT_CONST, 0.01144).

-endif.

-ifdef(__MYDLP_NETWORK).

-define(ACLQ_TIMEOUT_MIN, 300000).

-define(ACLQ_TIMEOUT_MAX, 900000).

-define(ACLQ_TIMEOUT_CONST, 0.0572).

-endif.

%%%% API

schedule_confupdate() -> gen_server:cast(?MODULE, schedule_confupdate).

confupdate() -> gen_server:call(?MODULE, confupdate).

get_ep_meta_dict() -> gen_server:call(?MODULE, get_ep_meta_dict).

get_ep_meta(Key) -> gen_server:call(?MODULE, {get_ep_meta, Key}).

set_ep_meta(Key, Val) -> gen_server:cast(?MODULE, {set_ep_meta, Key, Val}).

set_ep_meta_from_dict(MetaDict) -> gen_server:cast(?MODULE, {set_ep_meta_from_dict, MetaDict}).

unset_ep_meta(Key) -> gen_server:cast(?MODULE, {unset_ep_meta, Key}).

new() -> gen_server:call(?MODULE, new).

setprop(ObjId, Key, Value) -> gen_server:cast(?MODULE, {setprop, ObjId, Key, Value}).

getprop(ObjId, Key) -> gen_server:call(?MODULE, {getprop, ObjId, Key}).

getpropdict(ObjId) -> gen_server:call(?MODULE, {getpropdict, ObjId}).

push(ObjId, DataChunk) -> gen_server:cast(?MODULE, {push, ObjId, DataChunk}).

pushfile(ObjId, FilePath) -> gen_server:cast(?MODULE, {pushfile, ObjId, FilePath}).

pushchunk(ObjId, ChunkPath) -> gen_server:cast(?MODULE, {pushchunk, ObjId, ChunkPath}).

eof(ObjId) -> gen_server:cast(?MODULE, {eof, ObjId}).

getdata(ObjId) -> gen_server:call(?MODULE, {getdata, ObjId}).

obj_size(ObjId) -> gen_server:call(?MODULE, {obj_size, ObjId}).

get_trap_pid() -> gen_server:call(?MODULE, get_trap_pid).

set_trap_pid(Pid) -> gen_server:cast(?MODULE, {set_trap_pid, Pid}).
reset_trap_pid() -> set_trap_pid(undefined).

aclq_timeout(Size) -> 
	CalcSizeF = ?ACLQ_TIMEOUT_MIN + ( Size * ?ACLQ_TIMEOUT_CONST ),
	CalcSize = round(CalcSizeF),
	case CalcSize of
		I when I < ?ACLQ_TIMEOUT_MIN -> ?ACLQ_TIMEOUT_MIN;
		I when I > ?ACLQ_TIMEOUT_MAX -> ?ACLQ_TIMEOUT_MAX;
		I when is_integer(I)-> I end.

aclq(ObjId) -> 
	ObjSize = case obj_size(ObjId) of
		{error, _Else} -> 0;
		{ok, I} -> I end,
	Timeout = aclq_timeout(ObjSize),
	aclq(ObjId, Timeout).

aclq(ObjId, Timeout) ->
	case gen_server:call(?MODULE, {aclq, ObjId, Timeout}, Timeout) of
	{ierror, {Class, Error}} -> mydlp_api:exception(Class, Error);
	Else -> Else end.

destroy(ObjId) -> gen_server:cast(?MODULE, {destroy, ObjId}).

%%%%%%%%%%%%%% gen_server handles

handle_call(confupdate, _From, #state{confupdate=ConfUpdate} = State) ->
	{reply, ConfUpdate, State#state{confupdate=false}};

handle_call(get_ep_meta_dict, _From, #state{ep_meta=D} = State) ->
	{reply, D, State};

handle_call(get_trap_pid, _From, #state{trap_pid=TP} = State) ->
	{reply, TP, State};

handle_call({get_ep_meta, Key}, _From, #state{ep_meta=D} = State) ->
	Reply = case dict:find(Key, D) of
		{ok, Value} -> Value;
		error -> undefined end,
	{reply, Reply, State};

handle_call(new, _From, #state{object_tree=OT} = State) ->
	{_MegaSecs, Secs, MicroSecs} = erlang:now(),
	% we do not include MegaSecs, because timeout cleanup will schedule within a period less than 1000000 seconds.
	ObjId = 1000000*Secs + MicroSecs,
	OT1 = gb_trees:enter(ObjId, #object{}, OT),
	Reply = {ok, ObjId},
	{reply, Reply, State#state{object_tree=OT1}};

handle_call({getprop, ObjId, Key}, _From, #state{object_tree=OT} = State) ->
	Reply = case gb_trees:lookup(ObjId, OT) of
		{value, #object{prop_dict=PD}} -> 
				case dict:find(Key, PD) of
					{ok, Value} -> {ok, Value};
					error -> {error, not_in_prop_dict} end;
		none -> {error, not_in_object_tree} end,
	{reply, Reply, State};

handle_call({getpropdict, ObjId}, _From, #state{object_tree=OT} = State) ->
	Reply = case gb_trees:lookup(ObjId, OT) of
		{value, #object{prop_dict=PD}} -> {ok, PD};
		none -> {error, not_in_object_tree} end,
	{reply, Reply, State};

handle_call({aclq, ObjId, Timeout}, From, #state{object_tree=OT} = State) ->
	case gb_trees:lookup(ObjId, OT) of
		{value, #object{eof_flag=true} = Obj} -> 
			Worker = self(),
			SpawnOpts = get_spawn_opts(Obj),
			mydlp_api:mspawn(fun() -> 
					Return = try 
						File = object_to_file(Obj),
						DFFiles = [File],
						Channel = get_channel(Obj),
						{QRet, Obj1} = case Channel of
							api ->	
								IpAddress = get_ip_address(Obj),
								case get_api_user(Obj) of
									<<"api-nouser">> ->
										{EndpointId, UserName, UserHash, Hostname} = mydlp_mnesia:get_user_from_address(IpAddress),
										AclQ = #aclq{endpoint_id=EndpointId, channel=Channel, 
											src_addr=IpAddress, src_user_h=UserHash, src_hostname=Hostname},
										Obj2 = case UserName of
											nil -> del_api_user(Obj);
											U -> set_api_user(Obj, U) end,
										{mydlp_acl:q(AclQ, DFFiles), Obj2};
									Username -> AclQ = #aclq{channel=Channel, src_addr=IpAddress, src_user_h=mydlp_api:hash_un(Username)},
										{mydlp_acl:q(AclQ, DFFiles), Obj} end;
							discovery -> 
								RuleIndex = get_discovery_rule_index(Obj),
								{mydlp_acl:qe(Channel, DFFiles, RuleIndex), Obj};
							remote_discovery -> 
								RuleIndex = get_discovery_rule_index(Obj),
								{mydlp_acl:qr(RuleIndex, DFFiles), Obj};
							printer -> {mydlp_acl:qe(Channel, DFFiles), Obj};
							inbound -> {mydlp_acl:qi(Channel, DFFiles), Obj};
							removable -> {mydlp_acl:qe(Channel, DFFiles), Obj}
							end,
						AclRet = acl_ret(QRet, Obj1, DFFiles),
						{ok, AclRet}
					catch	throw:{error, eacces} -> {ok, pass};
						throw:{error, enomem} -> 
							?ERROR_LOG("ACLQ: Analysis of a file had failed because of insufficient memory!~nStacktrace: "?S, [erlang:get_stacktrace()]),
							{ok, pass};
						throw:{is_not_regularfile, Path} ->
							case catch string:substr(Path, 2, 2) of
								":\\" -> ok;
								_Else -> ?ERROR_LOG("ACLQ: Path is not a regular file. Can not aclq. Path: "?S, [Path]) end,
							{ok, pass};
						Class:Error ->
							?ERROR_LOG("ACLQ: Error occured: Class: ["?S"]. Error: ["?S"].~n"
									"Stack trace: "?S"~nObjID: ["?S"].~nState: "?S"~n ",
								[Class, Error, erlang:get_stacktrace(), ObjId, State]),
								{ierror, {Class, Error}} end,
					Worker ! {async_reply, Return, From}
				end, Timeout, SpawnOpts);
		{value, #object{eof_flag=false} = Obj} -> 
			?ERROR_LOG("ACLQ: eof_flag is not true, can not ACLQ before EOF: ObjId="?S", Obj="?S" OT="?S"~n",
				[ObjId, Obj, OT]),
			?SAFEREPLY(From, {error, eof_flag_is_not_true});
		none -> ?SAFEREPLY(From, {error, not_in_object_tree}) end,
	{noreply, State};

handle_call({obj_size, ObjId}, _From, #state{object_tree=OT} = State) ->
	Reply = case gb_trees:lookup(ObjId, OT) of
		{value, #object{eof_flag=true, size=Size}} -> 
			case Size of
				error -> {error, na};
				0 -> {error, na};
				I when is_integer(I) -> {ok, I} end;
		{value, #object{eof_flag=false} = Obj} -> 
			?ERROR_LOG("SIZE: eof_flag is not true, can not SIZE before EOF: ObjId="?S", Obj="?S" OT="?S"~n",
				[ObjId, Obj, OT]),
			{error, eof_flag_is_not_true};
		none -> {error, not_in_object_tree} end,
	{reply, Reply, State};

handle_call({getdata, ObjId}, _From, #state{object_tree=OT} = State) ->
	Reply = case gb_trees:lookup(ObjId, OT) of
		{value, #object{eof_flag=true, data=Data}} -> 
			{ok, Data};
		{value, #object{eof_flag=false} = Obj} -> 
			?ERROR_LOG("SIZE: eof_flag is not true, can not GETDATA before EOF: ObjId="?S", Obj="?S" OT="?S"~n",
				[ObjId, Obj, OT]),
			{error, eof_flag_is_not_true};
		none -> {error, not_in_object_tree} end,
	{reply, Reply, State};

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_cast(schedule_confupdate, State) ->
	{noreply, State#state{confupdate=true}};

handle_cast({set_ep_meta, Key, ""}, State) ->
	handle_cast({unset_ep_meta, Key}, State);

handle_cast({set_ep_meta, Key, nil}, State) ->
	handle_cast({unset_ep_meta, Key}, State);

handle_cast({set_ep_meta, Key, unknown}, State) ->
	handle_cast({unset_ep_meta, Key}, State);

handle_cast({set_ep_meta, Key, undefined}, State) ->
	handle_cast({unset_ep_meta, Key}, State);

handle_cast({set_ep_meta, Key, Value}, #state{ep_meta=D} = State) ->
	D1 = dict_store(Key, Value, D),
	{noreply, State#state{ep_meta=D1}};

handle_cast({set_ep_meta_from_dict, MetaDict}, #state{ep_meta=D} = State) ->
	D1 = set_meta_dict(MetaDict, D),
	{noreply, State#state{ep_meta=D1}};

handle_cast({set_trap_pid, TP}, State) ->
	{noreply, State#state{trap_pid=TP}};

handle_cast({unset_ep_meta, Key}, #state{ep_meta=D} = State) ->
	D1 = dict:erase(Key, D),
	{noreply, State#state{ep_meta=D1}};

handle_cast({setprop, ObjId, Key, Value}, #state{object_tree=OT} = State) ->
	case gb_trees:lookup(ObjId, OT) of
		{value, #object{prop_dict=PD} = Obj} -> 
			PD1 = dict:store(Key, Value, PD),
			OT1 = gb_trees:enter(ObjId, Obj#object{prop_dict=PD1}, OT),
			{noreply, State#state{object_tree=OT1}};
		none -> ?ERROR_LOG("SETPROP: Object not found in object_tree: ObjId="?S", Key="?S", Value="?S" ObjectTree="?S"~n",
				[ObjId, Key, Value, OT]),
			{noreply, State}
			end;

handle_cast({pushfile, ObjId, {raw, FilePath}}, #state{object_tree=OT} = State) ->
	case gb_trees:lookup(ObjId, OT) of
		{value, #object{eof_flag=false} = Obj} -> 
			OT1 = gb_trees:enter(ObjId, Obj#object{filepath=FilePath, buffer=[]}, OT),
			{noreply, State#state{object_tree=OT1}};
		{value, #object{eof_flag=true} = Obj} -> 
			?ERROR_LOG("PUSHFILE: eof_flag is true, not pushing file: ObjId="?S", FilePath="?S", Object="?S"~n",
				[ObjId, FilePath, Obj]),
			{noreply, State};
		none -> ?ERROR_LOG("PUSHFILE: Object not found in object_tree: ObjId="?S", ObjectTree="?S"~n",
				[ObjId, OT]),
			{noreply, State}
			end;

handle_cast({pushfile, ObjId, FilePath}, State) -> handle_cast({pushfile, ObjId, {raw, qp_decode(FilePath)}}, State);

handle_cast({pushchunk, ObjId, ChunkPath}, State) ->
	try	{ok, DataChunk} = file:read_file(ChunkPath),
		handle_cast({push, ObjId, DataChunk}, State)
	catch Class:Error ->
		?ERROR_LOG("PUSHCUNK: Error occured: Class: ["?S"]. Error: ["?S"].~nStack trace: "?S"~nObjID: ["?S"]. ChunkPath: ["?S"]~nState: "?S"~n ",
			[Class, Error, erlang:get_stacktrace(), ObjId, ChunkPath, State]),
		{noreply, State}
	end;

% could use dataref appends in push after a certain threshold.
handle_cast({push, ObjId, DataChunk}, #state{object_tree=OT} = State) ->
	case gb_trees:lookup(ObjId, OT) of
		{value, #object{eof_flag=false, filepath=undefined, buffer=Buffer} = Obj} -> 
			OT1 = gb_trees:enter(ObjId, Obj#object{buffer=[DataChunk|Buffer]}, OT),
			{noreply, State#state{object_tree=OT1}};
		{value, #object{eof_flag=true} = Obj} -> 
			?ERROR_LOG("PUSH: eof_flag is true, not pushing: ObjId="?S", DataChunk="?S", Object="?S"~n",
				[ObjId, DataChunk, Obj]),
			{noreply, State};
		{value, #object{eof_flag=false, filepath=FilePath} = Obj} -> 
			?ERROR_LOG("PUSH: Already pushed a file, not pushing data chunk: ObjId="?S", FilePath="?S", DataChunk="?S", Object="?S"~n",
				[ObjId, FilePath, DataChunk, Obj]),
			{noreply, State};
		none -> ?ERROR_LOG("PUSH: Object not found in object_tree: ObjId="?S", DataChunk="?S" ObjectTree="?S"~n",
				[ObjId, DataChunk, OT]),
			{noreply, State}
			end;

handle_cast({eof, ObjId}, #state{object_tree=OT} = State) ->
	case gb_trees:lookup(ObjId, OT) of
		{value, #object{eof_flag=false, filepath=undefined, buffer=Buffer} = Obj} -> 
			Data = list_to_binary(lists:reverse(Buffer)),
			Size = predict_size(Obj),
			OT1 = gb_trees:enter(ObjId, Obj#object{buffer=[], eof_flag=true, data=Data, size=Size}, OT),
			{noreply, State#state{object_tree=OT1}};
		{value, #object{eof_flag=false} = Obj} ->  % END after PUSHFILE
			Size = predict_size(Obj),
			OT1 = gb_trees:enter(ObjId, Obj#object{eof_flag=true, size=Size}, OT),
			{noreply, State#state{object_tree=OT1}};
		{value, #object{eof_flag=true} = Obj} -> 
			?ERROR_LOG("EOF: eof_flag is already true, doing nothing: ObjId="?S", Object="?S"~n",
				[ObjId, Obj]),
			{noreply, State};
		none -> ?ERROR_LOG("EOF: Object not found in object_tree: ObjId="?S", ObjectTree="?S"~n",
				[ObjId, OT]),
			{noreply, State}
			end;

handle_cast({destroy, ObjId}, #state{object_tree=OT} = State) ->
	OT1 = gb_trees:delete_any(ObjId, OT),
	{noreply, State#state{object_tree=OT1}};

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	?SAFEREPLY(From, Reply),
	{noreply, State};

handle_info(cleanup_now, #state{object_tree=OT} = State) ->
	OT1 = cleanup(OT),
	call_timer(),
        {noreply, State#state{object_tree=OT1}};

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

start_link() ->
	case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
		{ok, Pid} -> {ok, Pid};
		{error, {already_started, Pid}} -> {ok, Pid}
	end.

stop() ->
	gen_server:call(?MODULE, stop).

init([]) ->
	call_timer(),
	set_common_meta(),
	set_init_meta(),
	set_general_meta(),
	{ok, #state{ object_tree=gb_trees:empty(), ep_meta=dict:new() }}.

set_common_meta() ->
	?ASYNC0(fun() -> 
		set_ep_meta("has_enc_key", "no"),
		ok
	end),
	ok.

get_spawn_opts(#object{} = Object) -> get_spawn_opts1(get_channel(Object)).

get_spawn_opts1(discovery) -> [{priority, low}, {fullsweep_after, 0}];
get_spawn_opts1(remote_discovery) -> [{priority, low}, {fullsweep_after, 0}];
get_spawn_opts1(_Else) -> [].

-ifdef(__MYDLP_NETWORK).

set_init_meta() -> ok.

set_general_meta() -> ok.

-endif.

-ifdef(__MYDLP_ENDPOINT).

-ifdef(__PLATFORM_LINUX).

set_init_meta() ->
	?ASYNC0(fun() -> 
		set_ep_meta("os", "linux"),
		Version = mydlp_api:get_agent_version(),
		set_ep_meta("version", Version),
		ok
	end),
	ok.

set_general_meta() ->
	?ASYNC0(fun() -> 
		LoggedOnUser = mydlp_api:get_logged_on_user(),
		LoggedOnDomain = mydlp_api:get_logged_on_domain(),
		set_ep_meta("logged_on_domain", LoggedOnDomain),
		set_ep_meta("user", LoggedOnUser ++ "@" ++ LoggedOnDomain),
		set_ep_meta("hostname", LoggedOnDomain),
		ok
	end),
	ok.

-endif.

-ifdef(__PLATFORM_WINDOWS).

set_init_meta() ->
	?ASYNC0(fun() ->
		set_ep_meta("os", "windows")
	end),
	ok.

set_general_meta() -> ok.

-endif.

-endif.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

acl_ret(QRet, Obj, DFFiles) ->
	case case QRet of % TODO filepath as destination 
		pass -> {pass, mydlp_api:empty_aclr(DFFiles)};
		log -> {log, mydlp_api:empty_aclr(DFFiles)};
		archive -> {archive, mydlp_api:empty_aclr(DFFiles)};
		block -> {block, mydlp_api:empty_aclr(DFFiles)};
		quarantine -> {quarantine, mydlp_api:empty_aclr(DFFiles)};
		{custom, _} = CA -> {CA, mydlp_api:empty_aclr(DFFiles)};
		{pass, _AR} = T -> T;
		{log, _AR} = T -> T;
		{archive, _AR} = T -> T;
		{block, _AR} = T -> T;
		{quarantine, _AR} = T -> T;
		{{custom, _CD}, _AR} = T -> T
	end of
		{pass, _AclR} -> 	mydlp_api:clean_files(DFFiles),
					pass; 
		{log, AclR} -> 		log_req(Obj, log, AclR),
					pass; 
		{archive, AclR} -> 	log_req(Obj, archive, AclR),
					pass;
		{block, AclR} -> 	log_req(Obj, block, AclR),
					block;
		{quarantine, AclR} -> 	log_req(Obj, quarantine, AclR),
					block;
		{{custom, {Type, PrimAction, _Name, Param}} = CustomAction, AclR} -> 
					Message = execute_custom_action(Type, Param, Obj),
					log_req(Obj, CustomAction, AclR, Message),
					PrimAction
	end.

log_req(Obj, Action, {{rule, RuleId}, {file, File}, {itype, IType}, {misc, Misc}}, none) ->
	log_req(Obj, Action, {{rule, RuleId}, {file, File}, {itype, IType}, {misc, Misc}});
log_req(Obj, Action, {{rule, RuleId}, {file, File}, {itype, IType}, {misc, Misc}}, Message) ->
	case Misc of	"" -> ok;
			_Else -> ?ERROR_LOG("Misc was not empty. Misc: "?S, [Misc]) end,
	log_req(Obj, Action, {{rule, RuleId}, {file, File}, {itype, IType}, {misc, Message}}).

-ifdef(__PLATFORM_LINUX).

get_user(#object{prop_dict=PD}) ->
	case dict:find("user", PD) of
		{ok, User} -> User ++ "@" ++ get_ep_meta("logged_on_domain");
		_Else -> get_ep_meta("user") end.

-endif.

-ifdef(__PLATFORM_WINDOWS).

get_user(_Obj) -> get_ep_meta("user").

-endif.

log_req(#object{prop_dict=PD}=Obj, Action, {{rule, RuleId}, {file, File}, {itype, IType}, {misc, Misc}}) ->
	{User, GroupId} = case get_channel(Obj) of
				api -> {get_api_user(Obj), -1};
				remote_discovery -> {ok, RId} = dict:find("group_id", PD),
						{get_remote_user(Obj), RId};
				discovery -> {ok, RId} = dict:find("group_id", PD),
						{get_user(Obj), RId};
				_Else -> {get_user(Obj), -1} end,
	Channel = get_channel(Obj),
	Time = erlang:universaltime(),
	Destination = case get_destination(Obj) of
		undefined -> nil;
		Else -> Else end,
	log_req1(Time, Channel, RuleId, Action, User, Destination, IType, File, Misc, GroupId).

execute_custom_action(seclore, {HotFolderId, ActivityComments}, Obj) ->
	case get_destination(Obj) of % Assuming this is a discovery or endpoint object with a filepath,
		undefined -> ?ERROR_LOG("Can not protect object with file path. Obj: "?S, [Obj]);
		FilePath -> 
			FPRet = case  unicode:characters_to_binary(FilePath) of
					Bin when is_binary(Bin) -> {ok, Bin};
					_ -> {error, "mydlp.error.canNotEncodeFilePathAsUnicode"} end,
			case FPRet of
				{ok, FPB} -> case mydlp_tc:seclore_protect(FPB, HotFolderId, ActivityComments) of
						<<"ok ", Rest/binary>> -> <<"seclore.fileId ", Rest/binary>>;
						"ok" -> none;
						<<"ok">> -> none;
						Else -> Else end;
				{error, M} -> M end 
	end.

-ifdef(__MYDLP_ENDPOINT).

log_req1(Time, Channel, RuleId, Action, User, Destination, IType, File, Misc, GroupId) ->
	case {Channel, Action, Misc, ?CFG(ignore_discover_max_size_exceeded)} of
		{discovery, log, max_size_exceeded, true} -> ok;
		_Else2 -> ?ACL_LOG(#log{time=Time, channel=Channel, rule_id=RuleId, action=Action, ip=nil, user=User, destination=Destination, itype_id=IType, file=File, misc=Misc, group_id=GroupId}) end.

get_remote_user(_) -> "undefined".

-endif.

-ifdef(__MYDLP_NETWORK).

log_req1(Time, Channel, RuleId, Action, User, Destination, IType, File, Misc, GroupId) ->
	?ACL_LOG(#log{time=Time, channel=Channel, rule_id=RuleId, action=Action, ip=nil, user=User, destination=Destination, itype_id=IType, file=File, misc=Misc, group_id=GroupId}).

get_remote_user(#object{filepath=FP, prop_dict=PD}) ->
	case dict:find("web_server_id", PD) of
	{ok, WSId} -> WS = mydlp_mnesia:get_web_server(WSId),
			WS#web_server.proto ++ "://" ++ WS#web_server.address;
	_Else ->
		case filename:split(FP) of
			["/", "var", "lib", "mydlp", "mounts", Id|_Rest] -> construct_source(list_to_integer(Id));
			_ -> ?ERROR_LOG("Unknown remote discovery file", []), none
		end
	end.

construct_source(Id) ->
	case mydlp_mnesia:get_remote_storage_by_id(Id) of
		{sshfs, {Address, _, Path, _, _}} -> "sshfs://" ++ binary_to_list(Address) ++ ":" ++binary_to_list(Path);
		{ftpfs, {Address, Path, _, _}} -> "ftpfs://" ++ binary_to_list(Address) ++ binary_to_list(Path);
		{windows, {Address, _, _}} -> binary_to_list(Address);
		{nfs, {Address, Path}} -> "nfs://" ++ binary_to_list(Address) ++ "/" ++ binary_to_list(Path);
		none -> ?ERROR_LOG("Unknown remote storage with id: ["?S"]", [Id]), "none"
	end.


-endif.

is_inbound(#object{prop_dict=PD}) ->
	case dict:find("direction", PD) of
		{ok, "in"} -> true;
		{ok, "out"} -> false;
		{ok, _else} -> false;
		error -> false end.

get_channel(#object{prop_dict=PD} = Obj) ->
	case dict:find("channel", PD) of
		{ok, "discovery"} -> discovery;
		{ok, "api"} -> api;
		{ok, "remote_discovery"} -> remote_discovery;
	error -> case dict:find("printerName", PD) of
		{ok, _} -> printer;
		error -> case is_inbound(Obj) of
				true -> inbound;
				false -> removable end end end.

get_printer_name(#object{prop_dict=PD} = Obj) ->
	case dict:find("printerName", PD) of
		{ok, QPPrinterName} -> qp_decode(QPPrinterName);
		error ->
			?ERROR_LOG("Unexpected state for Obj: "?S, [Obj]),
			"Unknown printer" end.

get_discovery_rule_index(#object{prop_dict=PD}) ->
	case dict:find("rule_index", PD) of
		{ok, RuleIndex} -> RuleIndex;
		error -> none
	end.

	%case Ret of 
	%	none -> case dict:find("web_server_id", PD) of
	%		{ok, WebServerId} -> mydlp_mnesia:get_rule_id_by_web_server_id(WebServerId);
	%		error -> none end;
	%	R -> R
	%end.

get_type(#object{prop_dict=PD}) ->
	case dict:find("type", PD) of
		{ok, "usb_device"} -> usb_device;
		{ok, "regular"} -> regular;
		{ok, _Else} -> regular;
		error -> regular  end.

get_destination(#object{prop_dict=PD} = Obj) ->
	case dict:find("destination", PD) of
		{ok, Dest} -> Dest;
		error -> get_destination1(Obj) end.

get_destination1(#object{} = Obj) ->
	case get_channel(Obj) of
		discovery -> get_destination_file_path(Obj);
		removable -> get_destination_file_path(Obj);
		inbound -> get_destination_file_path(Obj);
		remote_discovery -> get_remote_destination_file_path(Obj);
		printer -> get_printer_name(Obj);
		_Else -> undefined end.

get_destination_file_path(#object{prop_dict=PD, filepath=FP}) ->
	case dict:find("fullpath", PD) of
		{ok, FullPath} -> qp_decode(FullPath);
		_Else -> 
			case dict:find("burn_after_reading", PD) of
				{ok, "true"} -> undefined;
				_Else2 -> FP 
			end
	end.

get_remote_destination_file_path(#object{filepath=FP, prop_dict=PD}) ->
	case dict:find("page_path", PD) of
		{ok, PP} -> PP;
		_Else ->
			case filename:split(FP) of
				["/", "var", "lib", "mydlp", "mounts", _Id|Rest] -> filename:join(Rest);
				_ -> ?ERROR_LOG("Unknown remote discovery file", []), undefined
			end
	end.
	
get_ip_address(#object{prop_dict=PD}) ->
	case dict:find("ip_address", PD) of
		{ok, ClientIpS} -> mydlp_api:str_to_ip(ClientIpS);
		error -> unknown  end.

set_api_user(#object{prop_dict=PD} = Obj, UserName) ->
	PD1 = dict:store("api_user", UserName, PD),
	Obj#object{prop_dict=PD1}.

get_api_user(#object{prop_dict=PD}) ->
	case dict:find("api_user", PD) of
		{ok, User} -> User;
		error ->
			case dict:find("ip_address", PD) of
				{ok, IP} -> IP;
				error -> nil  end end.

del_api_user(#object{prop_dict=PD}=Obj) ->
	PD1 = dict:erase("api_user", PD),
	Obj#object{prop_dict=PD1}.

predict_size(#object{filepath=undefined, data=undefined}) -> error;
predict_size(#object{filepath=undefined, data=Data}) -> size(Data);
predict_size(#object{filepath=FilePath}) -> filelib:file_size(FilePath).

object_to_file(Obj) ->
	Type = get_type(Obj),
	object_to_file(Type, Obj).

get_filename(#object{prop_dict=PD}) ->
	case dict:find("filename", PD) of
		{ok, FN} -> qp_decode(FN);
		error -> case dict:find("filename_unicode", PD) of
			{ok, UFN} -> UFN;
			error -> error end end.

object_to_file(regular, #object{filepath=undefined, data=Data} = Obj) ->
	Filename = case get_filename(Obj) of
		error -> "seap-data";
		Else -> Else end,
	?BF_C(#file{filename=Filename}, Data);

object_to_file(regular, #object{prop_dict=PD, filepath=FilePath} = Obj) ->  % created with PUSHFILE
	Filename = case get_filename(Obj) of
		error -> filename:basename(FilePath);
		Else -> Else end,
	URef = case dict:find("burn_after_reading", PD) of
		{ok, "true"} ->	{tmpfile, FilePath};
		_Else2 -> {regularfile, FilePath} end,
	?BF_C(#file{filename=Filename}, URef);

object_to_file(usb_device, #object{prop_dict=PD}) ->
	DeviceId = case dict:find("device_id", PD) of
		{ok, DId} -> DId;
		error -> "unknown" end,
	DeviceIdB = list_to_binary(DeviceId),
	#file{name="USB Device, device_id=" ++ DeviceId,
		mime_type= <<"mydlp-internal/usb-device;id=", DeviceIdB/binary>>}.


call_timer() -> timer:send_after(1000000, cleanup_now).

cleanup(OT) ->
	{_MegaSecs, Secs, MicroSecs} = erlang:now(),
	TSecs = case Secs > 1000 of % TODO: should use object update age not id
		true -> Secs - 1000;
		false -> 0 end,
	
	MinObjId = 1000000*TSecs + MicroSecs,
	ObjIds = gb_trees:keys(OT),
	cleanup1(OT, MinObjId, ObjIds).
	
cleanup1(OT, MinObjId, [ObjId| Rest]) when ObjId < MinObjId ->
	OT1 = gb_trees:delete_any(ObjId, OT),
	cleanup1(OT1, MinObjId, Rest);
cleanup1(OT, _MinObjId, _ObjIds) -> OT.

qp_decode(Str) -> mydlp_api:qp_decode(Str).

dict_store(Key, Value0, Dict) ->
	Value = qp_decode(Value0),
	dict:store(Key, Value, Dict).

set_meta_dict(MD, SD) -> set_meta_dict(dict:fetch_keys(MD), MD, SD).

set_meta_dict([Key|RestOfKeys], MD, SD) ->
	SD1 = case dict:fetch(Key, MD) of
		"" -> dict:erase(Key, SD);
		undefined -> dict:erase(Key, SD);
		unknown -> dict:erase(Key, SD);
		nil -> dict:erase(Key, SD);
		Value -> dict_store(Key, Value, SD) end,
	set_meta_dict(RestOfKeys, MD, SD1);
set_meta_dict([], _MD, SD) -> SD.

