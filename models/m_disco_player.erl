-module(m_disco_player).

-include("zotonic.hrl").
-define(table, disco_player).

-export(
   [
    init/1,
    get/2,
    get/3,
    get_other_player/2,
    set/3,
    set/4,
    insert/3,
    find_and_connect/3
   ]).

init(Context) ->
    case z_db:table_exists(?table, Context) of
        false ->
            z_db:create_table(
              ?table, 
              [
               #column_def{name=id, type="character varying", length=32, is_nullable=false, primary_key=true},
               #column_def{name=name, type="character varying", length=255, is_nullable=true},
               #column_def{name=secret_code, type="character varying", length=10, is_nullable=true},
               #column_def{name=status, type="character varying", length=32, is_nullable=true},
               #column_def{name=connected, type="boolean", is_nullable=true},
               #column_def{name=song_id, type="integer", is_nullable=true},
               #column_def{name=has_scored, type="boolean", is_nullable=true},
               #column_def{name=connected_to, type="varchar", length=32, is_nullable=true},
               #column_def{name=last_connected_to, type="varchar", length=32, is_nullable=true},
               #column_def{name=props, type="bytea", is_nullable=true}
              ], Context);
        true ->
            nop
    end,
    ok.

insert(Id, Props, Context) ->
    case get(Id, Context) of
        {ok, []} ->
             nop;
        {ok, _} ->
            z_db:delete(?table, Id, Context)
    end,
    z_db:insert(?table, [{id, Id}|Props], Context).

get(Id, Context) ->
    case z_db:select(?table, Id, Context) of
        {ok, []} -> {ok, []};
        {ok, Props} ->
            Score = m_disco_log:get_score(Id, Context),
            {ok, [{score, Score} | Props]}
    end.
             
get(Id, Key, Context) ->
    {ok, Player} = get(Id, Context),
    proplists:get_value(Key, Player).

get_other_player(Id, Context) ->
    get(get(Id, connected_to, Context), Context).

set(Id, Key, Value, Context) ->
    set(Id, [{Key, Value}], Context).

set(Id, Props, Context) ->
    z_db:update(?table, Id, Props, Context).


find_and_connect(PlayerId, SongId, Context) ->
    z_db:transaction(
      fun(C) ->
              case find_waiting(PlayerId, C) of
                  undefined ->
                      undefined;
                  PlayerB ->
                      connect(PlayerId, PlayerB, SongId, C),
                      PlayerB
              end
      end,
      Context).

find_waiting(PlayerId, Context) ->
    z_db:q1("SELECT id FROM disco_player WHERE id != $1 AND status = 'waiting' ORDER BY random() LIMIT 1",
            [PlayerId], Context).

connect(PlayerA, PlayerB, SongId, Context) ->
    set(PlayerA, [{status, buffering},
                  {connected_to, PlayerB},
                  {last_connected_to, PlayerB},
                  {song_id, SongId}], Context),
    set(PlayerB, [{status, buffering},
                  {connected_to, PlayerA},
                  {last_connected_to, PlayerA},
                  {song_id, SongId}], Context),
    ok.
