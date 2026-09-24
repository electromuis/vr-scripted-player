extends RefCounted

## Playlist: the next/previous order built from a folder listing.


static func test_from_paths_positions_on_current(t: TestCase) -> void:
	var paths: Array[String] = ["C:/v/a.mp4", "C:/v/b.mkv", "C:/v/c.json"]
	var pl := Playlist.from_paths(paths, "C:/v/b.mkv")
	t.assert_eq(pl.items.size(), 3)
	t.assert_eq(pl.index, 1)
	t.assert_eq(pl.step(1).get("path"), "C:/v/c.json")
	t.assert_eq(pl.step(1), {}, "stops at the end")
	t.assert_eq(pl.index, 2, "index stays on the last item")
	t.assert_eq(pl.step(-1).get("path"), "C:/v/b.mkv")


static func test_from_paths_drops_sidecars(t: TestCase) -> void:
	var paths: Array[String] = ["C:/v/a.json", "C:/v/a.mp4", "C:/v/b.mp4", "C:/v/solo.json"]
	var pl := Playlist.from_paths(paths, "C:/v/a.json")
	t.assert_eq(pl.items.map(func(it): return it["path"]), ["C:/v/a.mp4", "C:/v/b.mp4", "C:/v/solo.json"],
			"a.json plays through a.mp4, so it isn't listed twice")
	t.assert_eq(pl.index, 0, "opened sidecar stands on its video")


static func test_step_from_start_and_empty(t: TestCase) -> void:
	var pl := Playlist.new([{"path": "http://h/1.mp4", "name": "One.mp4"}, {"path": "http://h/2.mp4", "name": "Two.mp4"}], 0)
	t.assert_eq(pl.step(-1), {}, "nothing before the first")
	t.assert_eq(pl.step(1).get("name"), "Two.mp4")
	t.assert_true(Playlist.new().is_empty())
	t.assert_eq(Playlist.new().step(1), {})
