%% @description
%%
-module(deb).

-export([
   uptime/0
  ,mbox/1
  ,heap/1
  ,reductions/1
  ,supervised/1
]).

%%
%%
uptime() ->
   {UpTime, _}    = erlang:statistics(wall_clock),
   {D, {H, M, S}} = calendar:seconds_to_daystime(UpTime div 1000),
   lists:flatten(io_lib:format("~p days, ~p:~p:~p", [D,H,M,S])).


%%
%% mailbox size (message queue length)
-spec(mbox/1 :: ([pid()]) -> [{pid(), integer()}]).

mbox(Pids) ->
   pid_info(message_queue_len, Pids).

%%
%% heap size
-spec(heap/1 :: ([pid()]) -> [{pid(), integer()}]).

heap(Pids) ->
   pid_info(total_heap_size, Pids).

%%
%% process reductions
-spec(reductions/1 :: ([pid()]) -> [{pid(), integer()}]).

reductions(Pids) ->
   pid_info(reductions, Pids).

%%
%% return list of all worker processes (incl. nested) visible in tree
-spec(supervised/1 :: (atom() | pid()) -> [pid()]).

supervised(Sup) ->
   supervised(Sup, []).

supervised(Sup, Acc0) ->
   lists:foldl(
      fun
         ({_,Pid,worker,_},     Acc) -> [Pid|Acc];
         ({_,Pid,supervisor,_}, Acc) -> supervised(Pid, Acc)
      end,
      Acc0,
      supervisor:which_children(Sup)
   ).

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%%
pid_info(Attr, Pids) ->
   sort([{X, get_pid_info(Attr, X)} || X <- Pids]).

%%
%%
get_pid_info(Attr, Pid) ->
   case erlang:process_info(Pid) of
      undefined ->
         undefined;
      List      ->
         case lists:keyfind(Attr, 1, List) of
            false      -> undefined;
            {_, Value} -> Value
         end
   end.

%%
%%
sort(List) ->
   lists:reverse(lists:keysort(2, List)).

