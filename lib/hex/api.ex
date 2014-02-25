defmodule Hex.API do
  def get_user(username) do
    request(:get, api_url("users/#{username}"), [])
  end

  def new_user(username, email, password) do
    request(:post, api_url("users"), [],
            [username: username, email: email, password: password])
  end

  def get_package(name) do
    request(:get, api_url("packages/#{name}"), [])
  end

  def get_packages(search) do
    query = URI.encode_query([search: search])
    request(:get, api_url("packages?#{query}"), [])
  end

  def new_package(name, meta, auth) do
    request(:put, api_url("packages/#{name}"), auth(auth), [meta: meta])
  end

  def get_release(name, version) do
    request(:get, api_url("packages/#{name}/releases/#{version}"), [])
  end

  def new_release(name, version, url, ref, reqs, auth) do
    body = [ version: version,
             git_url: url,
             git_ref: ref,
             requirements: reqs ]
    request(:post, api_url("packages/#{name}/releases"), auth(auth), body)
  end

  def get_archives do
    request(:get, url("archives"), [])
  end

  def get_registry(filename) do
    request_file(:get, api_url("registry"), filename)
  end

  defp request(method, url, headers, body \\ nil) do
    headers = [ { 'accept', 'application/vnd.hex.beta+elixir' },
                { 'user-agent', 'Hex/' ++ String.to_char_list!(Hex.version) } ]
              ++ headers
    http_opts = [timeout: 5000]
    opts = [body_format: :binary]

    if body do
      request = { url, headers, 'application/vnd.hex+elixir', safe_serialize_elixir(body) }
    else
      request = { url, headers }
    end

    case :httpc.request(method, request, http_opts, opts) do
      { :ok, response } ->
        handle_response(response)
      { :error, reason } ->
        { :http_error, reason }
    end
  end

  defp request_file(method, url, filename) do
    headers = [ { 'accept', 'application/vnd.hex.beta+dets' },
                { 'user-agent', 'Hex/' ++ String.to_char_list!(Hex.version) } ]
    http_opts = [timeout: 5000]
    request = { url, headers }
    opts = [stream: String.to_char_list!(filename)]

    case :httpc.request(method, request, http_opts, opts) do
      { :ok, response } ->
        handle_response(response)
      { :error, reason } ->
        { :http_error, reason }
    end
  end

  defp handle_response(:saved_to_file) do
    :ok
  end

  defp handle_response({ { _version, code, _reason }, headers, body }) do
    handle_hex_message(headers['x-hex-message'])
    { code, safe_deserialize_elixir(body) }
  end

  @doc false
  def handle_hex_message(nil), do: :ok

  def handle_hex_message(header) do
    { message, level } = :binary.list_to_bin(header) |> parse_hex_message
    case level do
      "warn"  -> Mix.shell.info("API warning: " <> message)
      "fatal" -> Mix.shell.error("API error: " <> message)
      _       -> :ok
    end
  end

  defp url(path) do
    :binary.bin_to_list(Hex.url <> "/" <> path)
  end

  defp api_url(path) do
    :binary.bin_to_list(Hex.url <> "/api/" <> path)
  end

  defp auth(info) do
    base64 = :base64.encode_to_string(info[:user] <> ":" <> info[:password])
    [{ 'authorization', 'Basic ' ++ base64 }]
  end

  def safe_deserialize_elixir("") do
    nil
  end

  def safe_deserialize_elixir(string) do
    case Code.string_to_quoted(string, existing_atoms_only: true) do
      { :ok, ast } ->
        if Macro.safe_term(ast) do
          Code.eval_quoted(ast) |> elem(0)
        else
          raise Hex.Error, message: "received unsafe elixir from API"
        end
      _ ->
        raise Hex.Error, message: "received malformed elixir from API"
    end
  end

  def safe_serialize_elixir(term) do
    binarify(term)
    |> inspect(limit: :infinity, records: false, binaries: :as_strings)
  end

  defp binarify(binary) when is_binary(binary),
    do: binary
  defp binarify(atom) when is_atom(atom),
    do: atom_to_binary(atom)
  defp binarify(list) when is_list(list),
    do: lc(elem inlist list, do: binarify(elem))
  defp binarify({ left, right }),
    do: { binarify(left), binarify(right) }

  @space [?\s, ?\t]

  defp parse_hex_message(message) do
    { message, rest } = skip_ws(message) |> quoted
    level = skip_ws(rest) |> opt_level
    { message, level }
  end

  defp skip_ws(<< char, rest :: binary >>) when char in @space,
    do: skip_ws(rest)
  defp skip_ws(rest),
    do: rest

  defp skip_trail_ws(input, str \\ "", ws \\ "")

  defp skip_trail_ws(<< char, rest :: binary >>, str, ws) when char in @space,
    do: skip_trail_ws(rest, str, << ws :: binary, char >>)
  defp skip_trail_ws(<< char, rest :: binary >>, str, ws),
    do: skip_trail_ws(rest, << str :: binary, ws :: binary, char >>, "")
  defp skip_trail_ws("", str, _ws),
    do: str

  defp quoted("\"" <> rest),
    do: do_quoted(rest, "")

  defp do_quoted("\"" <> rest, acc),
    do: { acc, rest }
  defp do_quoted(<< char, rest :: binary >>, acc),
    do: do_quoted(rest, << acc :: binary, char >>)

  defp opt_level(";" <> rest),
    do: do_level(rest)
  defp opt_level(_),
    do: nil

  defp do_level(rest) do
    "level" <> rest = skip_ws(rest)
    "=" <> rest = skip_ws(rest)
    skip_ws(rest) |> skip_trail_ws
  end
end