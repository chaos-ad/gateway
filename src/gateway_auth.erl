-module(gateway_auth).

-export([login/2]).

login(_, <<"letmein">>) ->
    ok;

login(_, _) ->
    throw(invalid_password).
