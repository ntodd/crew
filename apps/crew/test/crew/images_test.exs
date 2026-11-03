defmodule Crew.ImagesTest do
  use Crew.VMCase

  alias Crew.Images
  alias Crew.Images.BoxImage

  defp age(box, image, seconds) do
    Repo.update_all(
      from(bi in BoxImage, where: bi.box_id == ^box.id and bi.image_id == ^image.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -seconds)]
    )
  end

  test "registering an image again returns the stored one" do
    [first | _] = Images.register_dev_images()
    [again | _] = Images.register_dev_images()
    assert {:ok, %{id: id}} = first
    assert {:ok, %{id: ^id}} = again
    assert Repo.get(Crew.Images.Image, id)
  end

  test "a prepare that has gone quiet for 30 minutes is retried", %{box: box, image: image} do
    Images.put_box_state(box.id, image.id, "downloading")
    assert Images.box_states()[{box.id, image.id}] == "downloading"
    age(box, image, 31 * 60)
    assert Images.box_states()[{box.id, image.id}] == "retry"
  end

  test "the inventory drops box images the agent doesn't have, but not one just sent", %{
    box: box,
    image: image
  } do
    other = Repo.get_by!(Crew.Images.Image, arch: "x64")
    online(box)
    age(box, image, 120)
    Images.put_box_state(box.id, other.id, "downloading")

    agent_event(box, "box.inventory", %{"vms" => [], "images" => []})
    states = Images.box_states()
    refute Map.has_key?(states, {box.id, image.id})
    assert states[{box.id, other.id}] == "downloading"
  end
end
