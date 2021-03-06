%% @author Arjan Scherpenisse
%% @copyright 2013 Arjan Scherpenisse
%% Generated on 2013-07-26
%% @doc This site was based on the 'empty' skeleton.

%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(silentmobiledisco).
-author("Arjan Scherpenisse").

-mod_title("silentmobiledisco zotonic site").
-mod_description("An empty Zotonic site, to base your site on.").
-mod_prio(10).

-include_lib("zotonic.hrl").

-export([broadcast_highscores/1]).

%% WS exports
-export([init/1, poll/1, ws_call/4, ws_cast/4, ws_opened/2, ws_closed/2]).


%%====================================================================
%% WS API
%%====================================================================

init(Context) ->
    case whereis(disco_poller) of
        undefined -> register(disco_poller, spawn_link(fun() -> poll(Context) end));
        _ -> nop
    end,
    ok.

ws_cast(disco_register, [{"name", Name}, {"user_agent", UserAgent}], From, Context) ->
    Player = player_id(Context),
    m_disco_player:insert(
      Player,
      [{connected, true},
       {user_agent, UserAgent},
       {status, registered},
       {connected_to, undefined},
       {ws, From},
       {name, Name}],
      Context),
    log("disco_register", [{player_id, Player}, {score, 0}], Context),
    broadcast_highscores(Context),
    ok;

ws_cast(disco_start, [], From, Context) ->
    Player = player_id(Context),
    set_waiting(Player, Context),
    m_disco_player:set(Player, [{connected, true}, {ws, From}], Context),
    find_waiting(Player, Context),
    send_player_state(Player, Context),
    send_stats_to_all_players(Context),
    ok;

ws_cast(disco_buffering_done, [], _From, Context) ->
    m_disco_player:set(player_id(Context), [{status, playing}, {has_scored, false}, {has_revealed, false}, {secret_code, secret_code()}, {playing_since, calendar:local_time()}], Context),
    {ok, Other} = m_disco_player:get_other_player(player_id(Context), Context),
    case proplists:get_value(status, Other) of
        <<"playing">> ->
            send_player_state(player_id(Context), Context),
            send_player_state(proplists:get_value(id, Other), Context),
            broadcast_highscores(Context),
            ok;
        _ -> 
            ok
    end;

ws_cast(disco_attach_highscores, [], From, Context) ->
    z_notifier:observe(disco_highscores, From, Context),
    broadcast_highscores(Context),
    nop;

ws_cast(disco_song_end, [], _From, Context) ->
    Player = player_id(Context),
    case m_disco_player:get(Player, status, Context) of
        <<"playing">> ->
            log("disco_next", [{player_id, Player}, {score, 1}], Context),
            set_waiting(Player, Context),
            send_player_state(Player, Context);
        _S ->
            lager:warning("Skip next_song for player in wrong state: ~p - ~p", [Player, _S])
    end,
    find_waiting(Player, Context);

ws_cast(disco_reveal_title, [], _From, Context) ->
    Player = player_id(Context),
    Other = m_disco_player:get(Player, connected_to, Context),

    m_disco_player:set(Player, [{has_revealed, true}], Context),
    m_disco_player:set(Other, [{has_revealed, true}], Context),
    
    log("disco_reveal_title", [{player_id, Player}, {score, -1}], Context),
    
    send_player_state(Player, Context),
    send_player_state(Other, Context),
    send_player_message(Other, "Your partner revealed the song title!", Context),
    ok;

ws_cast(disco_panic, [], _From, Context) ->
    Player = player_id(Context),
    lager:warning("Player pressed the panic button..: ~p", [Player]),
    ok;

ws_cast(disco_skip, [], _From, Context) ->
    skip_song(player_id(Context), Context).

ws_call(disco_connect, [], _From, Context) ->
    player_state(player_id(Context), Context);

ws_call(disco_init, [], _From, Context) ->
    Player = player_id(Context),
    m_disco_player:set(Player, [{status, registered}, {connected_to, undefined}], Context),
    case m_disco_player:get(Player, Context) of
        {ok, []} -> null;
        {ok, PlayerProps} ->
            proplists:get_value(name, PlayerProps)
    end;

ws_call(disco_guess, [{"code", Code}], _From, Context) ->
    Player = player_id(Context),
    {ok, Other} = m_disco_player:get_other_player(Player, Context),
    case z_convert:to_list(proplists:get_value(secret_code, Other)) =:= Code of
        true ->
            PlayerB = proplists:get_value(id, Other),
            m_disco_player:set(Player, [{has_scored, true}, {has_revealed, true}], Context),
            m_disco_player:set(PlayerB, [{has_scored, true}, {has_revealed, true}], Context),
            log("disco_score", [{player_id, Player}, {score, 10}], Context),
            log("disco_score", [{player_id, PlayerB}, {score, 10}], Context),
            send_player_state(Player, Context),
            send_player_state(PlayerB, Context),
            true;
        false ->
            log("disco_score_fail", [{player_id, Player}, {score, -1}, {code_entered, Code}, {other, Other}], Context),
            send_player_state(Player, Context),
            false
    end;
    
ws_call(disco_stop, [], _From, Context) ->
    player_stop(Context),
    z_session:set(player_id, undefined, Context),
    ok;

ws_call(_Cmd, _, _, _) ->
    unknown_call.

ws_opened(_From, _Context) ->
    ok.

ws_closed(_From, Context) ->
    player_stop(Context),
    ok.



%%====================================================================
%% support functions
%%====================================================================


send_player_message(PlayerId, Message, Context) ->
    {ok, Player} = m_disco_player:get(PlayerId, Context),
    WS = proplists:get_value(ws, Player),
    case is_pid(WS) andalso proplists:get_value(connected, Player) =:= true of
        true ->
            controller_websocket:websocket_send_data(WS, mochijson:encode({struct, [{message, Message}]}));
        false ->
            nop
    end.


send_player_state(PlayerId, Context) ->
    {ok, Player} = m_disco_player:get(PlayerId, Context),
    WS = proplists:get_value(ws, Player),
    case is_pid(WS) andalso proplists:get_value(connected, Player) =:= true of
        true ->
            controller_websocket:websocket_send_data(WS, mochijson:encode(player_state(PlayerId, Context)));
        false ->
            nop
    end.

player_state(PlayerId, Context) ->
    {ok, Player} = m_disco_player:get(PlayerId, Context),
    encode_player_json(Player, Context).
    
    
encode_player_json(Player, Context) ->
    ExtraProps = case proplists:get_value(status, Player) of
                     <<"buffering">> ->
                         Id = proplists:get_value(song_id, Player),
                         M = m_media:get(Id, Context),
                         [{filename, proplists:get_value(filename, M)}];
                     _ ->
                         []
                 end,
    TitleProps = case proplists:get_value(song_id, Player) of
                     undefined -> [];
                     SongId ->
                         [{title, z_html:unescape(z_trans:trans(m_rsc:p(SongId, title, Context), Context))}]
                 end,
    {ok, Other} = m_disco_player:get(proplists:get_value(connected_to, Player), Context),
    {struct, [{connected_player, {struct, encode_player(Other)}}] ++ ExtraProps ++ TitleProps ++ encode_player(Player)}.

encode_player(Player) ->
    lists:map(fun({K, undefined}) -> {K, null};
                 ({K, {{_,_,_},_}=V}) -> {K, z_dateformat:format(V, "Y-m-d H:i:s", en)};
                 (X) -> X end, proplists:delete(ws, Player)).
              
find_random_song(_PlayerId, Context) ->
    Audio = m_rsc:name_to_id_check(audio, Context),
    All = z_db:q("select r.id from rsc r left join disco_player p on (r.id = p.song_id AND p.connected = true AND p.status = 'playing') where r.category_id = $1 AND p.song_id IS NULL order by random() limit 1", [Audio], Context),
    case All of
        [] ->
            lager:warning("No free songs left...! Taking a random song."),
            hd(z_search:query_([{cat, audio}, {sort, "random"}], Context));
        [{Id}|_] ->
            Id
    end.


player_id(Context) ->
    case z_session:get_persistent(player_id, Context) of
        undefined ->
            Id = list_to_binary(z_ids:id()),
            z_session:set_persistent(player_id, Id, Context),
            Id;
        I -> I
    end.

secret_code() ->
    random:seed(erlang:now()),
    [$0+random:uniform(9) || _ <- lists:seq(1,4)].

log(Event, Props, Context) ->
    lager:warning(">> Event: ~p ~p", [Event, Props]),
    m_disco_log:add(Event, Props, Context).

find_waiting(Player, Context) ->
    SongId = find_random_song(Player, Context),
    case m_disco_player:find_and_connect(Player, SongId, Context) of
        undefined ->
            undefined;
        PlayerB ->
            log("song_start", [{player_id, Player}, {connected_to, PlayerB}, {song_id, SongId}], Context),
            send_player_state(PlayerB, Context)
    end,
    send_player_state(Player, Context).
    
player_stop(Context) ->
    player_stop(player_id(Context), Context).

player_stop(PlayerId, Context) ->
    {ok, Player} = m_disco_player:get(PlayerId, Context),
    case proplists:get_value(connected_to, Player) of
        undefined -> nop;
        B -> 
            send_player_message(B, "Your partner decided to quit, or hit the panic button..!", Context),
            set_waiting(B, Context),
            case m_disco_player:get(B, connected, Context) of
                true -> find_waiting(B, Context);
                false -> nop
            end
    end,
    m_disco_player:set(PlayerId, [{ws, undefined}, {connected, false}], Context),
    send_stats_to_all_players(Context),
    broadcast_highscores(Context),
    log("disco_stop", [{player_id, PlayerId}], Context).    

skip_song(Player, Context) ->
    Other = m_disco_player:get(Player, connected_to, Context),

    log("disco_skip", [{player_id, Player}, {score, -2}], Context),

    set_waiting(Player, Context),
    set_waiting(Other, Context),
    send_player_message(Other, "Your partner skipped the rest of this song... :-(", Context),
    send_player_state(Player, Context),
    send_player_state(Other, Context),
    broadcast_highscores(Context),
    find_waiting(Player, Context),
    ok.

set_waiting(PlayerId, Context) ->
    m_disco_player:set(PlayerId, [{status, waiting}, {connected_to, undefined}, {secret_code, undefined}], Context).
    
broadcast_highscores(Context) ->
    Highscores = lists:map(fun({PlayerId, Score}) ->
                                   {struct, P} = player_state(PlayerId, Context),
                                   [{score, Score} | P]
                           end,
                           m_disco_log:highscores(Context)),
    z_notifier:notify({disco_highscores, Highscores}, Context).



poll(Context) ->
    timer:sleep(5000),
    All = z_db:q("SELECT id, props FROM disco_player WHERE connected = true", Context),
    lists:foreach(fun({Id, Props}) ->
                          case proplists:get_value(ws, Props) of
                              undefined -> nop;
                              P when is_pid(P) ->
                                  case erlang:is_process_alive(P) of
                                      true ->
                                          nop;
                                      false ->
                                          player_stop(Id, Context)
                                  end
                          end
                  end,
                  All),
    ?MODULE:poll(Context).

player_pids(Context) ->
    All = z_db:q("SELECT id, props FROM disco_player WHERE connected = true", Context),
    lists:foldl(fun({_, Props}, Acc) ->
                        Pid = proplists:get_value(ws, Props),
                        case is_pid(Pid) and erlang:is_process_alive(Pid) of
                            true ->
                                [Pid|Acc];
                            false ->
                                Acc
                        end
                end,
                [], All).

send_stats_to_all_players(Context) ->
    Pids = player_pids(Context),
    Count = length(Pids),
    lists:foreach(fun(Pid) ->
                          controller_websocket:websocket_send_data(Pid, mochijson:encode({struct, [{online_count, Count}]}))
                  end,
                  Pids).

                          
