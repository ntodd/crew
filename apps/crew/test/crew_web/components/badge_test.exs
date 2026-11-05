defmodule CrewWeb.BadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CrewWeb.CoreComponents

  defp badge(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.badge {@attrs}>Busy</CoreComponents.badge>
    """)
  end

  # Work in flight (a busy VM) is blue, not the emerald accent, which
  # sits too close to success.
  test "running is its own color, soft and outline" do
    soft = badge(%{color: "running", dot: true, pulse: true})
    assert soft =~ "bg-running/10"
    assert soft =~ "text-running-ink"
    refute soft =~ "accent"

    assert badge(%{color: "running", variant: "outline"}) =~ "border-running/35"
  end
end
