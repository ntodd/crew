defmodule CrewGuest.StepRefTest do
  use ExUnit.Case, async: true

  alias CrewGuest.StepRef

  @valid ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  test "a timeline record id (a GUID) is its own step ref" do
    id = "7f1c2a0e-5b8d-4c3e-9a1f-2d4e6b8c0a13"
    assert StepRef.from(id) == id
  end

  test "anything else maps to a stable ref the guest API accepts" do
    for id <- ["has spaces", "<script>", String.duplicate("a", 65), "", "é"] do
      ref = StepRef.from(id)
      assert Regex.match?(@valid, ref), inspect(id)
      assert StepRef.from(id) == ref
    end

    refute StepRef.from("a b") == StepRef.from("a c")
  end
end
