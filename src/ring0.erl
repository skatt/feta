%% @description
%%    Ring is a consistent hashing schema on ring modulo 2^m
%%    The key space is divided into equally sized shards.
%%    Shards are claimed and release by nodes. There are two 
%%    allocation strategy   
%%   
%%    Strategy 1 (chord):
%%    This is classical chord ring. Node address 
%%    is derived from it's identifier. Node controls all
%%    complete shards clockwise from its address (successor
%%    shards)
%%     
%%    Strategy 2 (token):    
%%    Each node claims S/N shards (S number of shards, 
%%    N number of nodes). 
%%
%%    Strategy 3 (single):
%%    Each node claims a single partition only
%%
%% @todo
%%    * list is not optimal if number of shard is large, use gb_tree
%%    * predecessors with filter fun
-module(ring0).

-export([
   new/0, 
   new/1, 

   join/2, 
   join/3, 
   leave/2,

   address/2,
   members/1,
   member/2,

   shards/1,
   shards/2, 
   whereis/2,

   successors/2,
   predecessors/2,
   p/2,
   n/2
]).

%%
-record(ring, {
   type   = chord,  % shard allocation strategy
   m      =   8,    % ring modulo
   n      =   3,    % number of replica   
   hash   = md5,    % hash algorithm
   shard  =   8,    % number of shards
   node   =   0,    % number of nodes
   master =  [],    % list of node master shards
   shards =  []     % list of shards
}).

%%
%% create new ring
%% Options
%%   {type,    chord | token | single} - ring strategy
%%   {modulo,  integer()}  - ring module power of 2 is required
%%   {hash,    md5 | sha1} - ring hashing algorithm
%%   {shard,   integer()}  - number of shard 
%%   {replica, integer()}  - number of replicas
-spec(new/0 :: () -> #ring{}).
-spec(new/1 :: (list()) -> #ring{}).

new() ->
   new([]).
new(Opts) ->
   init(Opts, #ring{}).

init([{type, X} | Opts], R) ->
   init(Opts, R#ring{type=X});

init([{modulo, X} | Opts], R) ->
   init(Opts, R#ring{m=X});

init([{replica, X} | Opts], R) ->
   init(Opts, R#ring{n=X});

init([{hash, X} | Opts], R) ->
   init(Opts, R#ring{hash=X});

init([{shard, X} | Opts], R) ->
   % TODO: validate shard is modulo 2
   init(Opts, R#ring{shard=X});

init([{_, _} | Opts], R) ->
   init(Opts, R);

init([], R) ->
   reset(R).

%%
%% join node to the ring, exit on node address collision
-spec(join/2 :: (any(), #ring{}) -> #ring{}).
-spec(join/3 :: (any(), any(), #ring{}) -> #ring{}).

join(Node, Ring) ->
   join(Node, Node, Ring).

join(Addr, Node, #ring{type=chord}=R)
 when is_integer(Addr) ->
   chord_join(Addr, Node, R);

join(Addr, Node, #ring{type=token}=R)
 when is_integer(Addr) ->
   token_join(Addr, Node, R);

join(Addr, Node, #ring{type=single}=R)
 when is_integer(Addr) ->
   single_join(Addr, Node, R);

join(Addr, Node, Ring) ->
   join(address(Addr, Ring), Node, Ring).


%%
%% leave node
-spec(leave/2 :: (any(), #ring{}) -> #ring{}).

leave(Node, #ring{type=chord}=R) ->
   chord_leave(Node, R);

leave(Node, #ring{type=token}=R) ->
   token_leave(Node, R);

leave(Node, #ring{type=single}=R) ->
   single_leave(Node, R).


%%
%% maps key into address on the ring
-spec(address/2 :: (any(), #ring{}) -> integer()).

address(X, #ring{})
 when is_integer(X) ->
   X;

address({addr, X}, #ring{}) ->
   X;

address({hash, X}, #ring{m=M}) ->
   <<Addr:M, _/bits>> = X,
   Addr;

address(X, #ring{hash=md5, m=M}) ->
   <<Addr:M, _/bits>> = erlang:md5(term_to_binary(X)),
   Addr;

address(X, #ring{hash=sha1, m=M})->
   <<Addr:M, _/bits>> = crypto:sha(term_to_binary(X)),
   Addr.

%%
%% return list of ring members
-spec(members/1 :: (#ring{}) -> [any()]).

members(#ring{shards=Shards}) ->
   lists:usort([X || {_, X} <- Shards, X =/= undefined]).

%%
%% check if node belongs to ring and return its address
-spec(member/2 :: (any() | function(), #ring{}) -> false | {integer(), any()}).

member(Fun, #ring{shards=Shards}) 
 when is_function(Fun) ->
   case [X || {_, X} <- Shards, Fun(X)] of 
      []  -> false;
      Val -> hd(Val)
   end;

member(Node, #ring{master=Shards}) ->
   lists:keyfind(Node, 2, Shards).


%%
%% return list of shards owned by ring or node
-spec(shards/1 :: (#ring{}) -> [{integer(), any()}]).
-spec(shards/2 :: (any() | function(), #ring{}) -> [{integer(), any()}]).

shards(#ring{shards=Shards}) ->
   Shards.

shards(Fun, #ring{shards=Shards})
 when is_function(Fun) ->
   [{X, N} || {X, N} <- Shards, Fun(N)];

shards(Node, #ring{shards=Shards}) ->
   [{X, N} || {X, N} <- Shards, N =:= Node].

%%
%% lookup shard and node pair at address
-spec(whereis/2 :: (integer(), #ring{}) -> {integer(), any()}).

whereis(Addr, #ring{shards=Shards})
 when is_integer(Addr) ->
   hd(lists:dropwhile(fun({X, _}) -> X < Addr end, Shards)).


%%
%% return unique list of predecessors 
-spec(predecessors/2 :: (any(), #ring{}) -> [any()]).

predecessors(Addr, #ring{n=N, shards=Shards})
 when is_integer(Addr) ->
   {Head, Tail} = lists:partition(
       fun({X, _}) -> X >= Addr end,
       Shards
   ),
   lists:filter(
      fun(X) -> X =/= undefined end,
      lists:sublist(
         unique(lists:reverse(Tail) ++ lists:reverse(Head)),
         N
      )
   );

predecessors(Key, Ring) ->
   predecessors(address(Key, Ring), Ring).

%% 
%% return unique list of successors
-spec(successors/2 :: (any(), #ring{}) -> [any()]).

successors(Addr, #ring{n=N, shards=Shards})
 when is_integer(Addr) ->
   {Head, Tail} = lists:partition(
       fun({X, _}) -> X >= Addr end,
       Shards
   ),
   lists:filter(
      fun(X) -> X =/= undefined end,
      lists:sublist(
         unique(Head ++ Tail),
         N
      )
   );

successors(Key, Ring) ->
   successors(address(Key, Ring), Ring).

%%
p(Nodes, Shards) ->
   1 - math:pow( (Shards - 1) / Shards, Nodes * (Nodes - 1) / 2).

%%
n(P, Shards) ->
   math:sqrt(2 * Shards * 1 / (1 - P)).


%%%------------------------------------------------------------------
%%%
%%% chord ring
%%%
%%%------------------------------------------------------------------   

%%
chord_join(Addr, Node, #ring{node=0, master=Master, shards=Shards}=R) ->
   R#ring{
      node   = 1,
      master = [{Addr, Node} | Master],
      shards = [{X, Node} || {X, _} <- Shards] 
   };

chord_join(Addr, Node, #ring{node=S, master=Master, shards=Shards}=R) ->
   % new node claim interval from current owner 
   %  * start of interval is first shard owned by new node (new node request primary shard)
   %  * stop of interval is either last shard owned by old node of its first shard
   {A, Owner} = whereis(Addr, R), 
   {M,     _} = member(Owner, R),
   {B,     _} = whereis(M,    R),   
   % check against collisions
   if
      A =:= B -> 
         exit({collision, Addr, Node, Owner});
      true    ->
         R#ring{
            node   = S + 1,
            master = lists:keystore(Node, 2, Master, {Addr, Node}),
            shards = chord_claim(A, B, Node, Owner, Shards)
         }
   end.

%%
chord_leave(Node, #ring{type=chord, node=N, master=Master, shards=Shards}=R) ->
   {Addr, _} = lists:keyfind(Node, 2, Master),
   case hd(predecessors(Addr, R)) of
      % predecessor is same => last node leaves ring
      Node  ->
         reset(R);
      % got an owner 
      Owner ->    
         L = lists:map(
            fun
               ({X, Y}) when Y =:= Node -> {X, Owner};
               (X) -> X
            end,
            Shards
         ),
         R#ring{
            node   = N - 1,
            master = lists:keydelete(Node, 2, Master),
            shards = L
         }
   end.

%% claim ring internal
chord_claim(A, B, New, Old, Shards) ->
   lists:map(
      fun
      ({X, N}) when A < B, X >= A, X < B, N =:= Old ->  {X, New};
      ({X, N}) when A > B, X >= A, N =:= Old ->  {X, New};
      ({X, N}) when A > B, X <  B, N =:= Old ->  {X, New};
      ({_, _}=X) -> X
      end,
      Shards 
   ).


%%%------------------------------------------------------------------
%%%
%%% token ring
%%%
%%%------------------------------------------------------------------   

%%
token_join(Addr, Node, #ring{node=0, master=Master, shards=Shards}=R) ->
   %% @todo:
   %%  * initial node allocation shall claim only it own tokens
   %%  * predecessor / successors shall take into account undefined node and return previous value
   %%  * list is not optimal for high number of shards > 100
   R#ring{
      node   = 1,
      master = [{Addr, Node} | Master],
      shards = [{X, Node} || {X, _} <- Shards] 
   };

token_join(Addr, Node, #ring{node=S, shard=Q, master=Master, shards=Shards}=R) ->
   %T = tokens([Node | members(R)], R), %% give priority of shard to new node
   %% keep priority of shard to old node
   T = tokens(Q, members(R) ++ [Node], R), 
   L = lists:map(
      fun({X, N}) ->
         case lists:keyfind(X, 1, T) of
            false   -> {X, N};
            {_, NN} -> {X, NN}
         end
      end,
      Shards
   ),
   R#ring{
      node   = S + 1,
      master = lists:keystore(Node, 2, Master, {Addr, Node}),
      shards = L
   }.

 
token_leave(Node, #ring{node=S, shard=Q, master=Master, shards=Shards}=R) ->
   NShards = lists:filter(fun({_, N}) -> N =/= Node end, Shards),
   case tokens(2 * Q, lists:usort([X || {_, X} <- NShards]), R) of
      [] ->
         reset(R);
      T  ->
         % @todo: this is a quick fix to eliminate ring failure
         {_, Fallback} = hd(T),
         L = lists:map(
            fun
            ({X, N}) when N =:= Node ->
               case lists:keyfind(X, 1, T) of
                  false   -> {X, Fallback};
                  {_, NN} -> {X, NN}
               end;
            ({_, _}=X) -> X
            end,
            Shards
         ),
         R#ring{
            node   = S - 1,
            master = lists:keydelete(Node, 2, Master),
            shards = L
         }
   end.

%%
%% return list of N tokens for each node (ordered by token weight)
tokens(N, Nodes, Ring) ->
   lists:flatten(
      lists:map(
         fun(X) ->
            lists:map(
               fun(Node) ->
                  {Shard,    _} = whereis(address(hash(X, Node), Ring), Ring),
                  {Shard, Node}
               end,
               Nodes
            )
         end,
         lists:seq(1, N)
      )
   ).

%%%------------------------------------------------------------------
%%%
%%% single ring
%%%
%%%------------------------------------------------------------------   

%%
single_join(Addr, Node, #ring{node=S, master=Master, shards=Shards}=R) ->
   case whereis(Addr, R) of
      {A, undefined} ->
         R#ring{
            node   = S + 1,
            master = lists:keystore(Node, 2, Master, {Addr, Node}),
            shards = lists:usort(lists:keystore(A, 1, Shards, {A, Node}))
         };
      _ ->
         throw(collision)
   end.

%%
single_leave(Node, #ring{node=S, master=Master, shards=Shards}=R) ->
   case lists:keytake(Node, 2, Shards) of
      false  ->
         R;
      {value, {A, _}, List} ->
         R#ring{
            node   = S - 1,
            master = lists:keydelete(Node, 2, Master),
            shards = lists:usort([{A, undefined} | List])
         }
   end.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% reset ring
reset(#ring{m=M, shard=Q}=R) ->
   Top = trunc(math:pow(2,M)),
   Inc = Top div Q,
   R#ring{
      node   = 0,
      master = [], 
      shards = [{X, undefined} || X <- lists:seq(Inc - 1, Top - 1, Inc)]
   }.

%%
%%
hash(0, X) ->
   {hash, X};

hash(N, X)
 when is_binary(X) ->
   hash(N - 1, erlang:md5(X));

hash(N, X) ->
   hash(N, term_to_binary(X)).

%%
%% take unique list elements, preserving the order and skip undefined nodes
unique(List) ->
   lists:reverse(
      lists:foldl(
         fun({_, X}, Acc) ->
            case lists:member(X, Acc) of
               true  -> Acc;
               false -> [X | Acc]
            end
         end,
         [],
         List
      )
   ).

% %%
% %% map arc to node map
% arc_to_node(Arc) ->
%    lists:usort(arc_to_node(Arc, [])).

% arc_to_node([{Shard, Node}|T], Acc0) ->
%    case lists:keytake(Node, 1, Acc0) of
%       false -> 
%          arc_to_node(T, [{Node, [Shard]}|Acc0]);
%       {value, {_, List}, Acc} -> 
%          arc_to_node(T, [{Node, [Shard|List]}|Acc])
%    end;

% arc_to_node([], Acc) ->
%    Acc.

% %%
% %% map nodes to shards
% node_to_arc(Nodes) ->
%    lists:usort(
%       lists:flatten(node_to_arc(Nodes, []))
%    ).

% node_to_arc([{Node, []}|_T], _Acc) ->
%    throw({collision, Node});

% node_to_arc([{Node, Shards}|T], Acc) ->
%    node_to_arc(T, [[{X, Node} || X <- Shards] | Acc]);

% node_to_arc([], Acc) ->
%    Acc.


% %%
% %% add new node
% %% partitions are optimally balanced when each node has only one partition on arc.
% add_node(Node, Nodes) ->
%    lists:foldl(
%       fun
%       ({N, Shards}, [{NNode, []} | Acc]) when length(Shards) > 1 ->
%          {Head, Tail} = lists:split(length(Shards) - 1, Shards),
%          [{NNode, Tail}, {N, Head} | Acc];
%       (N, [NewNode|Acc]) ->
%          [NewNode, N | Acc]
%       end,
%       [{Node, []}],
%       Nodes
%    ).

% %%
% %%
% sub_node(Node, Nodes) ->
%    case lists:keytake(Node, 1, Nodes) of
%       false ->
%          Nodes;
%       {value, _, []} ->
%          [];
%       {value, {_, [Shard]}, List} ->
%          [{ONode, Shards} | T] = List,
%          [{ONode, [Shard|Shards]} | T]
%    end.   

% %%
% %% split ring into arcs, 
% arc(N, List) ->
%    arc(N, List, [], []).

% arc(N, List, Arc, Acc) when length(Arc) =:= N ->
%    arc(N, List, [], [Arc|Acc]);

% arc(N, [H|T], Arc, Acc) ->
%    arc(N, T, [H|Arc], Acc);

% arc(_, [], [], Acc) ->
%    Acc;

% arc(_, [], Arc, Acc) ->
%    [Arc | Acc].
