defmodule PtcManager.PollerWake do
  @moduledoc false

  def handle(%{task_ref: nil} = state, true, message) do
    state = clear_timer(state)
    send(self(), message)
    {:noreply, state}
  end

  def handle(state, _enabled, _message), do: {:noreply, state}

  def schedule(state, true, message, delay) when is_integer(delay) and delay >= 0 do
    state = clear_timer(state)
    %{state | timer_ref: Process.send_after(self(), message, delay)}
  end

  def schedule(state, _enabled, _message, _delay), do: clear_timer(state)

  def clear_timer(%{timer_ref: nil} = state), do: state

  def clear_timer(%{timer_ref: reference} = state) do
    Process.cancel_timer(reference, async: true, info: false)
    %{state | timer_ref: nil}
  end
end
