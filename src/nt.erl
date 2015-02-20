%%
%%   Copyright 2012 - 2014 Dmitry Kolesnikov, All Rights Reserved
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @description
%%   N-triples encode / decode (see http://www.w3.org/2001/sw/RDFCore/ntriples/)
%%
%%   doc         ::=   line*  
%%   line        ::=   ws* (comment | triple) ? eoln  
%%   comment     ::=   '#' (character - ( cr | lf ) )*   
%%   triple      ::=   subject ws+ predicate ws+ object ws* '.' ws*  
%%   subject     ::=   uriref | namedNode    
%%   predicate   ::=   uriref    
%%   object      ::=   uriref | namedNode | literal   
%%   uriref      ::=   '<' absoluteURI '>'   
%%   namedNode   ::=   '_:' name    
%%   literal     ::=   '"' string '"'  
%%   ws          ::=   space | tab  
%%   eoln        ::=   cr | lf | lf cr    
%%   string      ::=   character* with escapes. Defined in section Strings    
%%   name        ::=   [A-Za-z][A-Za-z0-9]*  
%%   absoluteURI ::=   ( character - ( '<' | '>' | space ) )+  
%%   character   ::=   [#x20-#x7E] 
%%   space       ::=   #x20   
%%   cr          ::=   #xD  
%%   lf          ::=   #xA 
%%   tab         ::=   #x9 
%%
-module(nt).

-export([
   new/0
  ,decode/2   
  ,stream/1
]).

%%
%% types
-type(triple() :: {binary(), binary(), binary()}).

%%
%% parser state
-record(nt, {
   recbuf = <<>> :: binary() %% internal receive buffer
}).

%% grammar  
-define(WS,  [<<$ >>, <<$\t>>, <<$\n>>]).
-define(EOL, <<$.>>).

%%
%% create new triple parser
-spec(new/0 :: () -> #nt{}).

new() ->
   #nt{}.

%%
%% stream decoder
-spec(stream/1 :: (stdio:stream()) -> stdio:stream()).

stream(Stream) ->
   stream(Stream, new()).

stream({},    _State) ->
   stdio:new();
stream(Stream, State) ->
   stream(stdio:head(Stream), Stream, State).

stream(Head, Stream, State0)
 when is_binary(Head) ->
   {NT, State} = decode(Head, State0),
   stream(NT, Stream, State);

stream([], Stream, State) ->
   stream(stdio:tail(Stream), State);
stream([Head|Tail], Stream, State) ->
   stdio:new(Head, fun() -> stream(Tail, Stream, State) end).

%%%------------------------------------------------------------------
%%%
%%% decoder
%%%
%%%------------------------------------------------------------------

%%
%% decode triple stream
%% returns parsed values and new parser state
-spec(decode/2 :: (binary(), #nt{}) -> {[triple()], #nt{}}).

decode(Chunk, #nt{recbuf = <<>>}=State)
 when is_binary(Chunk) ->
   decode(Chunk, [], State);

decode(Chunk, State)
 when is_binary(Chunk) ->
   decode(iolist_to_binary([State#nt.recbuf, Chunk]), [], State#nt{recbuf = <<>>}).

decode(Chunk, Acc, State) ->
   case decode_triple(Chunk) of
      %% unable to parse
      undefined   ->
         {lists:reverse(Acc), State#nt{recbuf = Chunk}};
      %% got a triple
      {SPO, Tail} ->
         decode(Tail, [SPO | Acc], State)
   end.

decode_triple(<<$#, X0/binary>>) ->
   case binary:split(X0, <<$\n>>) of
      [_, X1] ->
         decode_triple(X1);
      _       ->
         undefined
   end;

decode_triple(X0) ->
   try
      {S, X1} = decode_s(X0),
      {P, X2} = decode_p(X1),
      {O, X3} = decode_o(X2),
      case binary:split(X3, ?EOL) of
         [_, X4] ->
            {{S, P, O}, X4};
         _       ->
            undefined
      end
   catch throw:badarg ->
      undefined
   end.

%%
%%
decode_s(X) ->
   case split(X, ?WS) of
      {<<$_, $:, X/binary>>, Tail} ->
         {{url, <<"urn:", X/binary>>}, Tail};
      {<<>>,_Tail} ->
         throw(badarg);
      {Head, Tail} ->
         {Url,    _} = unquote(Head, <<$<>>, <<$>>>),
         {{url, Url}, Tail}
   end.

%%
%%
decode_p(X) ->
   case split(X, ?WS) of
      {<<>>,_Tail} ->
         throw(badarg);
      {Head, Tail} -> 
         {Url,     _} = unquote(Head, <<$<>>, <<$>>>),
         {{url, Url},  Tail}
   end.

%%
%%
decode_o(<<$<, _/binary>>=X) ->
   {Head, Tail} = unquote(X, <<$<>>, <<$>>>),
   {{url, Head}, Tail};

decode_o(<<$", _/binary>>=X) ->
   case unquote(X, <<$">>, <<$">>) of
      {Head, <<$@, Rest/binary>>} ->
         %% @todo: use language tag
         {_Lang, Tail} = skip(Rest, ?EOL),
         {Head,  Tail};

      {Head, <<$^, $^, Rest/binary>>} ->
         {Type, Tail} = unquote(Rest, <<$<>>, <<$>>>),
         {decode_l(Type, Head),  Tail};

      {_Head, _Tail} = Result ->
         Result
   end;

decode_o(_) ->
   throw(badarg).

%%
%% decode literal data type
decode_l(<<"http://www.w3.org/2001/XMLSchema#date">>, X) ->
   tempus:decode("%Y-%m-%d", X);

decode_l(<<"http://www.w3.org/2001/XMLSchema#dateTime">>, X) ->
   tempus:decode("%Y-%m-%dT%H:%M:%S", X);

decode_l(<<"http://www.w3.org/2001/XMLSchema#integer">>, X) ->
   scalar:i(X);

decode_l(<<"http://www.w3.org/2001/XMLSchema#string">>, X) ->
   X;

decode_l(_, X) ->
   scalar:decode(X).


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------

%%
%% split binary, return head and tail
split(Bin, Pat) ->
   case binary:split(Bin, Pat) of
      [<<>>, X] ->
         split(X, Pat);   
      [X] ->
         {X, <<>>};
      [H, T] ->
         {H, T}
   end.

%%
%% skip binary to pattern
skip(Bin, Pat) ->
   case binary:match(Bin, Pat) of
      {0, _} ->
         {<<>>, Bin};
      {A, _} ->
         {binary:part(Bin, 0, A - 1), binary:part(Bin, A, size(Bin) - A)};
      _      ->
         throw(badarg)
   end.

%%
%% unquote binary 
%% @todo: return error if quote pair do not exists
%%        make generic utility
unquote(Bin, Qa, Qb) ->
   case binary:split(Bin,  Qa) of
      [_, X] ->
         case match(X, Qb) of
            nomatch ->
               throw(badarg);
            At      ->
               H = binary:part(X, 0, At),
               T = binary:part(X, At + 1, byte_size(X) - At - 1),
               {H, T}
         end;
         % case binary:split(X, Qb) of
         %    [H, T] ->
         %       {H, T};
         %    [_] ->
         %       throw(badarg)
         % end;
      [X] ->
         {<<>>, X}
   end.

%%
%% match pattern and skip escape
match(Bin, Pat) ->
   match(0, byte_size(Bin), Bin, Pat).   

match(I, L, Bin, Pat) ->
   case binary:match(Bin, Pat, [{scope, {I, L}}]) of
      nomatch ->
         nomatch;
      {I,  _} ->
         I;

      {X,  _} ->
         case binary:at(Bin, X - 1) of
            $\\ ->
               match(X + 1, L - X - 1, Bin, Pat);
            _   ->
               X
         end
   end.








