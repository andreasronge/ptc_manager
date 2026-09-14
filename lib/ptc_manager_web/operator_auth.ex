defmodule PtcManagerWeb.OperatorAuth do
  @moduledoc """
  Bearer-token authentication for the operator read surface.

  The token is a maintainer credential next to the console password. It is
  read from the `Authorization` header only, never from a parameter or the
  body, and compared in constant time. A console without a configured token
  answers 404, so nothing reveals that the routes exist.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:ptc_manager, :operator_token) do
      nil ->
        refuse(conn, 404, "Not Found")

      expected ->
        case bearer_token(conn) do
          {:ok, token} ->
            if PtcManagerWeb.Auth.secure_match?(token, expected),
              do: assign(conn, :actor, "operator"),
              else: refuse(conn, 401, "Unauthorized")

          :error ->
            refuse(conn, 401, "Unauthorized")
        end
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, String.trim(token)}
      _other -> :error
    end
  end

  defp refuse(conn, status, detail) do
    conn
    |> then(fn conn ->
      if status == 401, do: put_resp_header(conn, "www-authenticate", "Bearer"), else: conn
    end)
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: %{detail: detail}}))
    |> halt()
  end
end
