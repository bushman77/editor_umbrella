defmodule Editor.OpenFileCacheTest do
  use ExUnit.Case, async: false

  test "caches opened files and broadcasts focused file updates" do
    path = "/tmp/editor-open-file-cache-#{System.unique_integer([:positive])}.txt"
    second_path = "/tmp/editor-open-file-cache-#{System.unique_integer([:positive])}.txt"
    content = "cached content"

    :ok = Editor.OpenFileCache.subscribe()

    assert {:ok, opened_file} = Editor.OpenFileCache.cache_file(path, content)
    assert opened_file.path == path
    assert opened_file.content == content
    assert opened_file.byte_size == byte_size(content)
    assert opened_file.in_focus?

    assert_receive {:open_files_updated, [%{path: ^path, in_focus?: true}]}
    assert {:ok, ^opened_file} = Editor.OpenFileCache.get(path)
    assert opened_file in Editor.OpenFileCache.list_files()

    assert {:ok, second_file} = Editor.OpenFileCache.cache_file(second_path, "second")

    assert_receive {:open_files_updated, updated_files}
    assert %{in_focus?: false} = Enum.find(updated_files, &(&1.path == path))
    assert %{in_focus?: true} = Enum.find(updated_files, &(&1.path == second_path))

    assert {:ok, focused_file} = Editor.OpenFileCache.focus_file(path)
    assert focused_file.in_focus?

    assert_receive {:open_files_updated, focused_files}
    assert %{in_focus?: true} = Enum.find(focused_files, &(&1.path == path))
    assert %{in_focus?: false} = Enum.find(focused_files, &(&1.path == second_path))

    assert :ok = Editor.OpenFileCache.delete_file(second_path)
    assert_receive {:open_files_updated, remaining_files}
    refute Enum.any?(remaining_files, &(&1.path == second_file.path))
  end
end
