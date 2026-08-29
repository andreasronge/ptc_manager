defmodule PtcManagerWeb.AuthControllerTest do
  use PtcManagerWeb.ConnCase, async: false

  test "redirects an unauthenticated visitor", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "rejects a wrong password", %{conn: conn} do
    conn = post(conn, ~p"/login", %{password: "wrong"})
    assert html_response(conn, 200) =~ "That password did not match"
    refute get_session(conn, :authenticated)
  end

  test "renews the session for the configured password", %{conn: conn} do
    conn = post(conn, ~p"/login", %{password: "test-password"})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :authenticated)
    assert get_session(conn, :actor) == "maintainer"
  end
end
