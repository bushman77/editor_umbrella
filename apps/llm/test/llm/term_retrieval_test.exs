defmodule Llm.TermRetrievalTest do
  use ExUnit.Case, async: false

  alias Llm.ContextPack.TermRetrieval
  alias Llm.ProjectMemory.FileChunk

  describe "terms/1" do
    test "keeps identifiers, numbers and content words; drops question filler" do
      terms =
        TermRetrieval.terms(
          "Where does the 500-credit first_pay payout get added, and what stops it paying twice?"
        )

      assert "500" in terms
      assert "credit" in terms
      assert "first_pay" in terms
      assert "first" in terms
      assert "payout" in terms
      refute Enum.any?(terms, &String.ends_with?(&1, "?"))
      refute "where" in terms
      refute "does" in terms
      refute "twice" in terms
      refute "the" in terms
    end

    test "strips simple plurals" do
      assert TermRetrieval.terms("medical crates and credits") == ["medical", "crate", "credit"]
    end
  end

  describe "top_chunks/3" do
    test "ranks by distinct matching terms, skips excluded files and caps per file" do
      memory = %{
        files: %{
          "lib/story.ex" => %{
            chunks: [
              chunk("lib/story.ex", 10, "Repo.update_all(inc: [credits: Prologue.first_pay()])"),
              chunk("lib/story.ex", 30, "def credits_label, do: :credit"),
              chunk("lib/story.ex", 50, "first_pay credits receipt payout 500")
            ]
          },
          "lib/story/prologue.ex" => %{
            chunks: [chunk("lib/story/prologue.ex", 1, "@first_pay 500 credits payout")]
          },
          "lib/traffic.ex" => %{chunks: [chunk("lib/traffic.ex", 1, "def lane, do: :mars")]}
        }
      }

      chunks =
        TermRetrieval.top_chunks(memory, "where is the 500 credit first_pay payout?",
          exclude_paths: ["lib/story/prologue.ex"]
        )

      assert Enum.map(chunks, &{&1.path, &1.start_line}) == [
               {"lib/story.ex", 50},
               {"lib/story.ex", 10}
             ]
    end

    test "skips docs and tests unless the question asks for them" do
      memory = %{
        files: %{
          "ROADMAP.md" => %{
            chunks: [chunk("ROADMAP.md", 1, "credit payout first_pay 500 ledger")]
          },
          "test/story_test.exs" => %{
            chunks: [chunk("test/story_test.exs", 1, "credit payout first_pay 500")]
          },
          "lib/story.ex" => %{chunks: [chunk("lib/story.ex", 1, "credit payout")]}
        }
      }

      paths = &Enum.map(TermRetrieval.top_chunks(memory, &1), fn chunk -> chunk.path end)

      assert paths.("500 credit first_pay payout") == ["lib/story.ex"]
      assert "test/story_test.exs" in paths.("which test covers the 500 credit payout?")
      assert "ROADMAP.md" in paths.("what does the roadmap say about the credit payout?")
    end

    test "returns nothing when the question has no useful terms" do
      memory = %{files: %{"a.ex" => %{chunks: [chunk("a.ex", 1, "anything")]}}}
      assert TermRetrieval.top_chunks(memory, "what does it do?") == []
    end
  end

  describe "Llm.Rag.snippet_context/4" do
    setup do
      unless Process.whereis(Llm.ProjectMemory.Cache) do
        start_supervised!({Llm.ProjectMemory.Cache, []})
      end

      root =
        Path.join(System.tmp_dir!(), "llm-snippet-context-#{System.unique_integer([:positive])}")

      prologue = Path.join(root, "lib/game/story/prologue.ex")
      story = Path.join(root, "lib/game/story.ex")
      traffic = Path.join(root, "lib/game/traffic.ex")

      File.mkdir_p!(Path.dirname(prologue))

      File.write!(prologue, """
      defmodule Game.Story.Prologue do
        @first_pay 500

        def first_pay, do: @first_pay

        def apply(%{step: 9} = progress, :arrived, _facts), do: {:ok, progress, [:deliver]}
      end
      """)

      File.write!(story, """
      defmodule Game.Story do
        alias Game.Story.Prologue

        defp db_effect!(player_id, :deliver) do
          receipt = Repo.insert(%Reward{user_id: player_id, credits: Prologue.first_pay()},
            on_conflict: :nothing)

          case receipt do
            {:ok, %Reward{id: id}} when is_integer(id) ->
              Repo.update_all(PlayerAccount, inc: [credits: Prologue.first_pay()])

            {:ok, _already_paid} ->
              :ok
          end
        end

        defp db_effect!(_player_id, :noop), do: :ok
      end
      """)

      File.write!(traffic, """
      defmodule Game.Traffic do
        def lane(:earth), do: :mars
      end
      """)

      on_exit(fn -> File.rm_rf!(root) end)

      %{root: root, prologue: prologue, story: story}
    end

    test "finds the payout code in another file and skips the selected one", %{
      root: root,
      prologue: prologue
    } do
      assert {:ok, text} =
               Llm.Rag.snippet_context(
                 root,
                 prologue,
                 "Where does the 500-credit first-run payout get added to the balance, and what stops it paying twice?"
               )

      assert text =~ "FILE: lib/game/story.ex"
      assert text =~ "inc: [credits: Prologue.first_pay()]"
      refute text =~ "FILE: lib/game/story/prologue.ex"
      refute text =~ "Game.Traffic"
    end

    test "respects exclude_paths and max_chars", %{root: root, prologue: prologue, story: story} do
      question = "Where is the 500 credit first_pay payout added?"

      assert {:ok, ""} =
               Llm.Rag.snippet_context(root, prologue, question, exclude_paths: [story])

      assert {:ok, ""} = Llm.Rag.snippet_context(root, prologue, question, max_chars: 20)
    end
  end

  defp chunk(path, start_line, content) do
    %FileChunk{
      id: "#{path}:#{start_line}",
      path: path,
      chunk_index: start_line,
      start_line: start_line,
      end_line: start_line + 5,
      content: content,
      sha256: "x"
    }
  end
end
