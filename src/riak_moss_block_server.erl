%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_moss_block_server).

-behaviour(gen_server).

-include("riak_moss.hrl").
-include_lib("riakc/include/riakc_obj.hrl").

%% API
-export([start_link/0,
         start_link/1,
         start_block_servers/2,
         get_block/5,
         put_block/6,
         delete_block/5,
         stop/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {riakc_pid :: pid(),
                close_riak_connection=true :: boolean()}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(RiakPid) ->
    gen_server:start_link(?MODULE, [RiakPid], []).

%% @doc Start (up to) 'MaxNumServers'
%% riak_moss_block_server procs.
%% 'RiakcPid' must be a Pid you already
%% have for a riakc_pb_socket proc. If the
%% poolboy boy returns full, you will be given
%% a list of less than 'MaxNumServers'.

%% TODO: this doesn't guarantee any minimum
%% number of workers. I could also imagine
%% this function looking something
%% like:
%% start_block_servers(RiakcPid, MinWorkers, MaxWorkers, MinWorkerTimeout)
%% Where the function works something like:
%% Give me between MinWorkers and MaxWorkers,
%% waiting up to MinWorkerTimeout to get at least
%% MinWorkers. If the timeout occurs, this function
%% could return an error, or the pids it has
%% so far (which might be less than MinWorkers).
-spec start_block_servers(pid(), pos_integer()) -> [pid()].
start_block_servers(RiakcPid, 1) ->
    {ok, Pid} = start_link(RiakcPid),
    [Pid];
start_block_servers(RiakcPid, MaxNumServers) ->
    case start_link() of
        {ok, Pid} ->
            [Pid | start_block_servers(RiakcPid, (MaxNumServers - 1))];
        {error, normal} ->
            start_block_servers(RiakcPid, 1)
    end.

-spec get_block(pid(), binary(), binary(), binary(), pos_integer()) -> ok.
get_block(Pid, Bucket, Key, UUID, BlockNumber) ->
    gen_server:cast(Pid, {get_block, self(), Bucket, Key, UUID, BlockNumber}).

-spec put_block(pid(), binary(), binary(), binary(), pos_integer(), binary()) -> ok.
put_block(Pid, Bucket, Key, UUID, BlockNumber, Value) ->
    gen_server:cast(Pid, {put_block, self(), Bucket, Key, UUID, BlockNumber, Value}).

-spec delete_block(pid(), binary(), binary(), binary(), pos_integer()) -> ok.
delete_block(Pid, Bucket, Key, UUID, BlockNumber) ->
    gen_server:cast(Pid, {delete_block, self(), Bucket, Key, UUID, BlockNumber}).

stop(Pid) ->
    gen_server:call(Pid, stop, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([RiakPid]) ->
    process_flag(trap_exit, true),
    {ok, #state{riakc_pid=RiakPid,
                close_riak_connection=false}};
init([]) ->
    process_flag(trap_exit, true),
    case riak_moss_utils:riak_connection() of
        {ok, RiakPid} ->
            {ok, #state{riakc_pid=RiakPid}};
        {error, all_workers_busy} ->
            {stop, normal}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({get_block, ReplyPid, Bucket, Key, UUID, BlockNumber}, State=#state{riakc_pid=RiakcPid}) ->
    dt_entry(<<"get_block">>, [BlockNumber], [Bucket, Key]),
    {FullBucket, FullKey} = full_bkey(Bucket, Key, UUID, BlockNumber),
    StartTime = os:timestamp(),
    GetOptions = [{r, 1}, {notfound_ok, false}, {basic_quorum, false}],
    ChunkValue = case riakc_pb_socket:get(RiakcPid, FullBucket, FullKey, GetOptions) of
        {ok, RiakObject} ->
            {ok, riakc_obj:get_value(RiakObject)};
        {error, notfound}=NotFound ->
            NotFound
    end,
    ok = riak_cs_stats:update_with_start(block_get, StartTime),
    ok = riak_moss_get_fsm:chunk(ReplyPid, BlockNumber, ChunkValue),
    dt_return(<<"get_block">>, [BlockNumber], [Bucket, Key]),
    {noreply, State};
handle_cast({put_block, ReplyPid, Bucket, Key, UUID, BlockNumber, Value}, State=#state{riakc_pid=RiakcPid}) ->
    dt_entry(<<"put_block">>, [BlockNumber], [Bucket, Key]),
    {FullBucket, FullKey} = full_bkey(Bucket, Key, UUID, BlockNumber),
    RiakObject0 = riakc_obj:new(FullBucket, FullKey, Value),
    MD = dict:from_list([{?MD_USERMETA, [{"RCS-bucket", Bucket},
                                         {"RCS-key", Key}]}]),
    _ = lager:debug("put_block: Bucket ~p Key ~p UUID ~p", [Bucket, Key, UUID]),
    _ = lager:debug("put_block: FullBucket: ~p FullKey: ~p", [FullBucket, FullKey]),
    RiakObject = riakc_obj:update_metadata(RiakObject0, MD),
    StartTime = os:timestamp(),
    ok = riakc_pb_socket:put(RiakcPid, RiakObject),
    ok = riak_cs_stats:update_with_start(block_put, StartTime),
    riak_moss_put_fsm:block_written(ReplyPid, BlockNumber),
    dt_return(<<"put_block">>, [BlockNumber], [Bucket, Key]),
    {noreply, State};
handle_cast({delete_block, _ReplyPid, Bucket, Key, UUID, BlockNumber}, State=#state{riakc_pid=RiakcPid}) ->
    dt_entry(<<"delete_block">>, [BlockNumber], [Bucket, Key]),
    {FullBucket, FullKey} = full_bkey(Bucket, Key, UUID, BlockNumber),
    StartTime = os:timestamp(),
    ok = riakc_pb_socket:delete(RiakcPid, FullBucket, FullKey),
    ok = riak_cs_stats:update_with_start(block_delete, StartTime),
    %% TODO:
    %% add a public func to riak_moss_delete_fsm
    %% to send messages back to the fsm
    %% saying that the block was deleted
    dt_return(<<"delete_block">>, [BlockNumber], [Bucket, Key]),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{riakc_pid=RiakcPid,
                          close_riak_connection=CloseConn}) ->
    case CloseConn of
        true ->
            riak_moss_utils:close_riak_connection(RiakcPid),
            ok;
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec full_bkey(binary(), binary(), binary(), pos_integer()) -> {binary(), binary()}.
%% @private
full_bkey(Bucket, Key, UUID, BlockNumber) ->
    PrefixedBucket = riak_moss_utils:to_bucket_name(blocks, Bucket),
    FullKey = riak_moss_lfs_utils:block_name(Key, UUID, BlockNumber),
    {PrefixedBucket, FullKey}.

dt_entry(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_BLOCK_OP, 1, Ints, ?MODULE, Func, Strings).

dt_return(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_BLOCK_OP, 2, Ints, ?MODULE, Func, Strings).
