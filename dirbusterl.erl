-module(dirbusterl).
-compile([export_all]).

-define(TRIES, 8).
-define(BACKOFF_LIMIT, 16384).
-define(BACKOFF_INTERVAL, 64).
-define(BACKOFF_MSEC, 3000).
-define(ENABLED(X), proplists:get_bool(X, Config)).

bust(URL) -> bust(URL, []).
bust(URL, UserConfig) ->
	URLs = ets:new(dirbusterl_urls, [named_table]),
	{Inputs, Config} = process_inputs_open(process_url_restriction(UserConfig)),
	Waiter = spawn_link(?MODULE, waiter, [self(), Config]),
	process_url_lists(Inputs, Waiter, filter_burst_config(Config)),
	WordList = proplists:get_value(wordlist, Inputs),
	bust(URL, dir, Waiter, WordList, Config),
	process_inputs_close(Inputs),
	ets:delete(URLs).

bust(URL, Mode, Waiter, WordList, Config) ->
	spawn_worker(URL, Waiter, proplists:get_value(http_cfg, Config, [])),
	case Mode of
		dir ->
			file:position(WordList, bof),
			BaseURL = url_tools:ensure_ends_with_slash(URL),
			burst_wordlist(BaseURL, WordList, Waiter, filter_burst_config(Config));
		_ -> ok
	end,
	Waiter ! finished,
	server_loop(Waiter, WordList, Config).

process_url_lists([], _, _) -> ok;
process_url_lists([{url_list, URLList} | Inputs], Waiter, Config) ->
	burst_wordlist(url_list, URLList, Waiter, Config),
	process_url_lists(Inputs, Waiter, Config);
process_url_lists([_ | Inputs], Waiter, Config) ->
	process_url_lists(Inputs, Waiter, Config).

process_inputs_open(Config) -> process_inputs_open(Config, [], []).
process_inputs_open([], InputsAcc, ConfigAcc) -> {InputsAcc, ConfigAcc};
process_inputs_open([{Type, FileName} | Config], InputsAcc, ConfigAcc)
  when Type =:= wordlist; Type =:= url_list ->
	{ok, FP} = file:open(FileName, [read, raw, read_ahead, binary]),
	process_inputs_open(Config, [{Type, FP} | InputsAcc], ConfigAcc);
process_inputs_open([Item | Config], InputsAcc, ConfigAcc) ->
	process_inputs_open(Config, InputsAcc, [Item | ConfigAcc]).

process_inputs_close([]) -> ok;
process_inputs_close([{_, FP} | Inputs]) ->
	file:close(FP),
	process_inputs_close(Inputs).

filter_burst_config(Config) -> filter_burst_config(Config, []).
filter_burst_config([], Acc) -> Acc;
filter_burst_config([Item | Config], Acc)
  when element(1, Item) =:= postfix; element(1, Item) =:= http_cfg ->
	filter_burst_config(Config, [Item | Acc]);
filter_burst_config([_ | Config], Acc) ->
	filter_burst_config(Config, Acc).

server_loop(Waiter, WordList, Config) ->
	receive
		{bust_file, {Base, Path}} ->
			BareBase = lists:reverse(url_tools:subslashes(lists:reverse(Base))),
			try_bust(url_tools:urljoin(BareBase, Path), file, Waiter, WordList, Config);
		{bust_file, Target} ->
			try_bust(Target, file, Waiter, WordList, Config);
		{bust_dir, Target} ->
			try_bust(Target, dir, Waiter, WordList, Config);
		done -> done
	end.

try_bust(URL, Mode, Waiter, WordList, Config) ->
	case url_allowed(URL, Config) of
		true ->
			Waiter ! started,
			bust(URL, Mode, Waiter, WordList, Config);
		false ->
			server_loop(Waiter, WordList, Config)
	end.

url_allowed(URL, Config) ->
	case proplists:get_value(url_restriction, Config) of
		undefined -> true;
		Restriction -> Restriction(URL)
	end.

process_url_restriction([{url_restriction, Restriction} | Config]) ->
	Value = case Restriction of
				X when is_list(X) ->
					{ok, RE} = re:compile(X),
					fun(URL) -> re:run(URL, RE, [{capture, none}]) =:= match end
			end,
	[{url_restriction, Value} | Config];
process_url_restriction([Item | Config]) -> [Item | process_url_restriction(Config)];
process_url_restriction([]) -> [].

waiter(Server, Config) -> waiter(Server, Config, 1).
waiter(Server, _, 0) -> Server ! done;
waiter(Server, Config, NProcs) ->
	NewProcs = receive
		started -> NProcs + 1;
		finished -> NProcs - 1;
		{get, Pid} -> Pid ! {nprocs, NProcs}, NProcs;
		{finished, URL, Code, Contents} ->
			Spec = case Contents of
					   dir -> " [DIR]";
					   {redir, To} -> " -> " ++ To;
					   _ -> ""
				   end,
			io:format("~s ~s~s\n", [Code, URL, Spec]),
			case {?ENABLED(follow_dirs), ?ENABLED(follow_redirs), Contents} of
				{true, _, dir} -> Server ! {bust_dir, URL ++ "/"};
				{_, true, {redir, Target}} -> Server ! {bust_file, {URL, Target}};
				{_, _, Body} when Code =/= error, is_list(Body) ->
					spawn_link(?MODULE, found_file, [Body, URL, Server, Config]);
				_ -> ok
			end,
			NProcs - 1
	end,
	waiter(Server, Config, NewProcs).

found_file(Body, URL, Server, Config) ->
	case ?ENABLED(parse_body) of
		true -> spawn_link(?MODULE, parse_body, [Body, URL, Server]);
		false -> nop
	end,
	mangle_found(proplists:get_value(mangle_found, Config, []), URL, Server).

mangle_found([], _, _) -> done;
mangle_found([Rule | Rest], URL, Server) ->
	Server ! {bust_file, re:replace(URL, "/([^/]+)$", "/" ++ Rule, [{return, list}])},
	mangle_found(Rest, URL, Server).

parse_body(Body, URL, Server) ->
	parse_body_values(extract_paths_from_body(Body), URL, Server).

-define(BODY_RE_HTML_ATTRIBS, "(?:src|href|action)=(?:\"([^\"]+)\"|'([^']+)'|([^ >]+)[ >])").
-define(BODY_RE_ROBOTS_TXT, "(?:(?:dis)?allow|sitemap): (.*)\\n").
-define(BODY_RE_CSS_URL, "url\\(['\"]?([^'\")]+)['\"]?\\)").

extract_paths_from_body(Body) ->
	case re:run(Body, "(?:" ?BODY_RE_HTML_ATTRIBS "|" ?BODY_RE_ROBOTS_TXT "|" ?BODY_RE_CSS_URL ")",
		   [global, {capture, all, list}, caseless]) of
		{match, Results} -> lists:map(fun lists:last/1, Results);
		nomatch -> []
	end.

parse_body_values([], _, _) -> ok;
parse_body_values([Result | Rest], URL, Server) ->
	Value = string:sub_word(string:sub_word(Result, 1, $?), 1, $#), %% remove ?... #...
	Server ! {bust_file, {URL, Value}},
	parse_body_values(Rest, URL, Server).

burst_wordlist(BaseURL, WordList, Waiter, Config) ->
	burst_wordlist(BaseURL, WordList, Waiter, Config, ?BACKOFF_INTERVAL).
burst_wordlist(BaseURL, WordList, Waiter, Config, 0) ->
	Waiter ! {get, self()},
	receive
		{nprocs, N} when N > ?BACKOFF_LIMIT ->
			timer:sleep(?BACKOFF_MSEC),
			burst_wordlist(BaseURL, WordList, Waiter, Config, 0);
		{nprocs, _} -> burst_wordlist(BaseURL, WordList, Waiter, Config)
	end;
burst_wordlist(BaseURL, WordList, Waiter, Config, Check) ->
	NewCheck = case file:read_line(WordList) of
		{ok, <<$#, _/binary>>} -> Check;
		{ok, <<$\n>>} -> Check;
		{ok, Line} ->
			Postfix = binary_to_list(Line, 1, byte_size(Line) - 1),
			Params = proplists:get_value(http_cfg, Config, []),
			case BaseURL of
				url_list -> spawn_worker(Postfix, Waiter, Params);
				_ ->
					UserPF = ["" | proplists:get_value(postfix, Config, [])],
					[spawn_worker(
					   BaseURL ++ ibrowse_lib:url_encode(Postfix) ++ PF,
					   Waiter, Params) || PF <- UserPF]
			end,
			Check - 1;
		eof -> ok
	end,
	case NewCheck of
		ok -> ok;
		_ -> burst_wordlist(BaseURL, WordList, Waiter, Config, NewCheck)
	end.

spawn_worker(URL, Waiter, Params) ->
	case ets:insert_new(dirbusterl_urls, {URL}) of
		true ->
			Waiter ! started,
			spawn_link(dirbusterl, try_url, [URL, Waiter, Params]);
		false -> already_requested
	end.

try_url(URL, Waiter, Params) -> try_url(URL, Waiter, Params, head).
try_url(URL, Waiter, Params, Method) -> try_url(URL, Waiter, Params, Method, ?TRIES).
try_url(URL, Waiter, Params, Method, N) ->
	case ibrowse:send_req(URL, [], Method, [], Params, infinity) of
		{ok, "404", _, _} -> Waiter ! finished;
		{ok, _, _, _} when Method =:= head -> try_url(URL, Waiter, Params, get);
		{ok, Code, Headers, Body} ->
			Payload = case get_location(Headers) of
				no_location -> Body;
				Location ->
					case is_dir_redir(URL, Location) of
						true -> dir;
						false -> {redir, Location}
					end
			end,
			Waiter ! {finished, URL, Code, Payload};
		{error, retry_later} -> timer:sleep(100), try_url(URL, Waiter, Params, Method, N);
		{error, _} when N > 0 -> try_url(URL, Waiter, Params, Method, N - 1);
		{error, Reason} -> Waiter ! {finished, URL, error, Reason}
	end.

get_location([]) -> no_location;
get_location([{Header, Value} | Rest]) ->
	case string:to_lower(Header) of
		"location" -> Value;
		_ -> get_location(Rest)
	end.

is_dir_redir([C | URL], [C | Loc]) ->
	is_dir_redir(URL, Loc);
is_dir_redir("", "/") -> true;
is_dir_redir(_, _) -> false.
