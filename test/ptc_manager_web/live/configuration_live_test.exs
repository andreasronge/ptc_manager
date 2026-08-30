defmodule PtcManagerWeb.ConfigurationLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import Plug.Conn

  alias PtcManager.PromptConfiguration

  test "lists every button prompt and saves and resets instructions", %{conn: conn} do
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert html =~ "Agent prompt instructions"
    assert has_element?(view, "nav", "Configuration")
    assert has_element?(view, "#prompt-private_issue_analysis", "Investigate privately")
    assert has_element?(view, "#prompt-implement_issue", "Approve and start")
    assert has_element?(view, "#prompt-prepare_issue", "Button: Prepare issue")
    assert has_element?(view, "#prompt-review_issue", "Button: Review issue")
    assert has_element?(view, "#prompt-repair_pr", "Button: Fix")
    assert has_element?(view, "#prompt-repair_and_merge_pr", "Button: Fix and merge")
    assert has_element?(view, "#prompt-implement_issue", "Agent retrospective")

    view
    |> form("#prompt-repair_and_merge_pr form", %{
      "action-key" => "repair_and_merge_pr",
      "customization" => %{
        "instructions" => "Mention the merge commit SHA in the final evidence."
      }
    })
    |> render_submit()

    assert PromptConfiguration.instructions("repair_and_merge_pr") ==
             "Mention the merge commit SHA in the final evidence."

    assert has_element?(view, "#prompt-repair_and_merge_pr", "Customized")

    view
    |> element("#prompt-repair_and_merge_pr button[phx-click=reset-prompt]")
    |> render_click()

    assert is_nil(PromptConfiguration.instructions("repair_and_merge_pr"))
    assert has_element?(view, "#prompt-repair_and_merge_pr", "Default")
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end
end
