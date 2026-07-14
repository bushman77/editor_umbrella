# apps/llm/test/llm/architectural_lens_test.exs
defmodule Llm.ArchitecturalLensTest do
  use ExUnit.Case, async: true

  alias Llm.ArchitecturalLens

  describe "detect/1" do
    @tag :tmp_dir
    test "categorizes a typical umbrella project structure", %{tmp_dir: tmp_dir} do
      # Build a mini umbrella structure mimicking payroll-calculator
      create_umbrella_structure(tmp_dir)

      layers = ArchitecturalLens.detect(tmp_dir)

      # Data layer: modules with defstruct
      assert "Employee" in layers.data
      assert "Core.PayrunStore.Run" in layers.data
      assert "Core.PayrunStore.Line" in layers.data

      # Functional core: pure modules with functions but no GenServer/side effects
      assert "Core.PayPeriod" in layers.functional_core
      assert "Core.Tax" in layers.functional_core
      assert "Core.Paystub" in layers.functional_core

      # Boundaries: modules with Database/Store/Client in name
      assert Enum.any?(layers.boundaries, &String.contains?(&1, "Database"))
      assert Enum.any?(layers.boundaries, &String.contains?(&1, "PayrunStore"))

      # Lifecycles: Application/Supervisor modules
      assert "Company.Application" in layers.lifecycles
      assert "Payroll.Application" in layers.lifecycles

      # Workers: GenServers, Tasks, Agents
      assert "Payroll" in layers.workers
      assert "Company" in layers.workers
      assert "Database" in layers.workers
    end

    @tag :tmp_dir
    test "handles flat (non-umbrella) project structure", %{tmp_dir: tmp_dir} do
      create_flat_structure(tmp_dir)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "MyApp.Worker" in layers.workers
      assert "MyApp.PureLogic" in layers.functional_core
      assert "MyApp.DataStruct" in layers.data
      refute layers.data == []
      refute layers.functional_core == []
    end

    @tag :tmp_dir
    test "returns empty lists for directory with no Elixir files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "readme.md"), "# Not Elixir")
      File.write!(Path.join(tmp_dir, "config.json"), "{}")

      layers = ArchitecturalLens.detect(tmp_dir)

      assert layers.data == []
      assert layers.functional_core == []
      assert layers.boundaries == []
      assert layers.lifecycles == []
      assert layers.workers == []
    end

    @tag :tmp_dir
    test "ignores _build and deps directories", %{tmp_dir: tmp_dir} do
      # Real source
      create_umbrella_structure(tmp_dir)

      # Junk that should be ignored
      build_dir = Path.join([tmp_dir, "_build", "dev", "lib", "some_app", "ebin"])
      File.mkdir_p!(build_dir)
      File.write!(Path.join(build_dir, "JunkModule.beam"), "binary junk")

      deps_dir = Path.join([tmp_dir, "deps", "some_dep", "lib"])
      File.mkdir_p!(deps_dir)

      File.write!(Path.join(deps_dir, "dep_module.ex"), """
      defmodule DepModule do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, [])
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      refute "DepModule" in layers.workers
      refute "JunkModule" in layers.workers
    end

    @tag :tmp_dir
    test "ignores test files", %{tmp_dir: tmp_dir} do
      create_umbrella_structure(tmp_dir)

      test_dir = Path.join([tmp_dir, "apps", "core", "test"])
      File.mkdir_p!(test_dir)

      File.write!(Path.join(test_dir, "core_test.exs"), """
      defmodule CoreTest do
        use ExUnit.Case

        def run_tests do
          :ok
        end
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      refute "CoreTest" in layers.functional_core
    end
  end

  describe "categorization edge cases" do
    @tag :tmp_dir
    test "module with defstruct and many functions is categorized as data", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "apps/myapp/lib/data.ex", """
      defmodule MyData do
        defstruct [:name, :value]

        @spec new(String.t(), integer()) :: t()
        def new(name, value), do: %__MODULE__{name: name, value: value}

        @spec validate(t()) :: :ok | {:error, term()}
        def validate(%__MODULE__{name: n}) when is_binary(n), do: :ok
        def validate(_), do: {:error, :invalid}

        @spec to_map(t()) :: map()
        def to_map(%__MODULE__{} = d), do: Map.from_struct(d)
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "MyData" in layers.data
    end

    @tag :tmp_dir
    test "pure module with no specs but many functions is functional core", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "lib/calculator.ex", """
      defmodule Calculator do
        def add(a, b), do: a + b
        def subtract(a, b), do: a - b
        def multiply(a, b), do: a * b
        def divide(a, b), do: a / b
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "Calculator" in layers.functional_core
    end

    @tag :tmp_dir
    test "module with GenServer but also defstruct is worker, not data", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "lib/hybrid.ex", """
      defmodule Hybrid do
        use GenServer
        defstruct [:state]

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

        def init(opts), do: {:ok, opts}

        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "Hybrid" in layers.workers
    end

    @tag :tmp_dir
    test "module with side effects is not functional core", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "lib/file_processor.ex", """
      defmodule FileProcessor do
        def read_config(path) do
          File.read(path)
        end

        def write_output(path, data) do
          File.write(path, data)
        end

        def process(path) do
          {:ok, content} = read_config(path)
          String.upcase(content)
        end
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      refute "FileProcessor" in layers.functional_core
    end

    @tag :tmp_dir
    test "Supervisor module is lifecycle, not worker", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "lib/my_supervisor.ex", """
      defmodule MySupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "MySupervisor" in layers.lifecycles
      # Has start_link but is supervisor, shouldn't be in workers
      refute "MySupervisor" in layers.workers
    end

    @tag :tmp_dir
    test "Task module is categorized as worker", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "lib/background_worker.ex", """
      defmodule BackgroundWorker do
        use Task

        def start_link(_opts) do
          Task.start_link(&run/0)
        end

        def run do
          :ok
        end
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "BackgroundWorker" in layers.workers
    end

    @tag :tmp_dir
    test "Agent module is categorized as worker", %{tmp_dir: tmp_dir} do
      write_module(tmp_dir, "lib/state_cache.ex", """
      defmodule StateCache do
        use Agent

        def start_link(_opts) do
          Agent.start_link(fn -> %{} end, name: __MODULE__)
        end

        def get(key) do
          Agent.get(__MODULE__, &Map.get(&1, key))
        end
      end
      """)

      layers = ArchitecturalLens.detect(tmp_dir)

      assert "StateCache" in layers.workers
    end
  end

  describe "format_for_prompt/1" do
    @tag :tmp_dir
    test "produces readable prompt text with all layers", %{tmp_dir: tmp_dir} do
      create_umbrella_structure(tmp_dir)

      prompt = ArchitecturalLens.format_for_prompt(tmp_dir)

      assert prompt =~ "Do Fun Things With Big Loud Worker Bees"
      assert prompt =~ "Data:"
      assert prompt =~ "Functional Core:"
      assert prompt =~ "Tests:"
      assert prompt =~ "Boundaries:"
      assert prompt =~ "Lifecycles:"
      assert prompt =~ "Worker Bees:"
      assert prompt =~ "When analyzing a module, identify which layer it belongs to."
    end

    @tag :tmp_dir
    test "handles empty project gracefully", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))

      prompt = ArchitecturalLens.format_for_prompt(tmp_dir)

      assert prompt =~ "Do Fun Things With Big Loud Worker Bees"
      assert prompt =~ "none detected"
    end

    @tag :tmp_dir
    test "includes detected module names in output", %{tmp_dir: tmp_dir} do
      create_umbrella_structure(tmp_dir)

      prompt = ArchitecturalLens.format_for_prompt(tmp_dir)

      assert prompt =~ "Employee"
      assert prompt =~ "Core.PayPeriod"
      assert prompt =~ "Database"
      assert prompt =~ "Payroll"
      assert prompt =~ "Company.Application"
    end

    @tag :tmp_dir
    test "boundary entries include keyword hints", %{tmp_dir: tmp_dir} do
      create_umbrella_structure(tmp_dir)

      prompt = ArchitecturalLens.format_for_prompt(tmp_dir)

      # Should show something like "Database (Database, Store)"
      assert prompt =~ "Database"
      assert Regex.match?(~r/Database\s+\(Database\)/, prompt)
    end
  end

  describe "list limits" do
    @tag :tmp_dir
    test "data layer caps at 8 modules", %{tmp_dir: tmp_dir} do
      # Create 10 data modules
      for i <- 1..10 do
        write_module(tmp_dir, "apps/myapp/lib/data_#{i}.ex", """
        defmodule MyData#{i} do
          defstruct [:field_#{i}]
        end
        """)
      end

      layers = ArchitecturalLens.detect(tmp_dir)

      assert length(layers.data) <= 8
    end

    @tag :tmp_dir
    test "functional core caps at 8 modules", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        write_module(tmp_dir, "apps/myapp/lib/pure_#{i}.ex", """
        defmodule Pure#{i} do
          @spec calc(integer()) :: integer()
          def calc(x), do: x * #{i}
        end
        """)
      end

      layers = ArchitecturalLens.detect(tmp_dir)

      assert length(layers.functional_core) <= 8
    end

    @tag :tmp_dir
    test "workers caps at 8 modules", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        write_module(tmp_dir, "apps/myapp/lib/worker_#{i}.ex", """
        defmodule Worker#{i} do
          use GenServer

          def start_link(_), do: GenServer.start_link(__MODULE__, [])
          def init(_), do: {:ok, %{}}
        end
        """)
      end

      layers = ArchitecturalLens.detect(tmp_dir)

      assert length(layers.workers) <= 8
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_umbrella_structure(root) do
    # Company app
    write_module(root, "apps/company/lib/company/application.ex", """
    defmodule Company.Application do
      use Application

      def start(_type, _args) do
        children = [{Database, []}, {Company, []}, {Payroll, []}]
        Supervisor.start_link(children, strategy: :one_for_one, name: Company.Supervisor)
      end
    end
    """)

    write_module(root, "apps/company/lib/company.ex", """
    defmodule Company do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
      def settings, do: GenServer.call(__MODULE__, :settings)

      def init(:ok), do: {:ok, %{}}
      def handle_call(:settings, _from, state), do: {:reply, state, state}
    end
    """)

    # Core app
    write_module(root, "apps/core/lib/core.ex", """
    defmodule Core do
      @spec add_hours_entry(map()) :: :ok | {:error, term()}
      def add_hours_entry(attrs) when is_map(attrs) do
        Database.insert1({Hours, attrs.full_name, attrs.date, "07:00", "15:00", 25.0, 8.0, ""})
      end

      @spec cpp_deduction(integer(), float(), pos_integer()) :: float()
      def cpp_deduction(year, gross, periods) do
        gross * 0.0595
      end
    end
    """)

    write_module(root, "apps/core/lib/core/pay_period.ex", """
    defmodule Core.PayPeriod do
      @spec current_period() :: map()
      def current_period do
        %{start_date: Date.utc_today(), end_date: Date.utc_today()}
      end

      @spec period_for_date(Date.t()) :: map()
      def period_for_date(date) do
        %{start_date: date, end_date: date}
      end
    end
    """)

    write_module(root, "apps/core/lib/core/tax.ex", """
    defmodule Core.Tax do
      @spec withholding(map()) :: float()
      def withholding(%{gross: gross}) do
        gross * 0.15
      end
    end
    """)

    write_module(root, "apps/core/lib/core/paystub.ex", """
    defmodule Core.Paystub do
      @spec build_from_run(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
      def build_from_run(run, line, opts \\\\ []) do
        {:ok, %{run: run, line: line, opts: opts}}
      end
    end
    """)

    write_module(root, "apps/core/lib/core/payrun_store.ex", """
    defmodule Core.PayrunStore do
      defmodule Run do
        defstruct [:run_id, :inserted_at, :pay_date]
      end

      defmodule Line do
        defstruct [:run_id, :full_name, :hours, :gross]
      end

      def save_run(payrun) do
        Database.insert1({Run, "pr_123", DateTime.utc_now(), Date.utc_today()})
        {:ok, "pr_123", :created}
      end
    end
    """)

    # Database app
    write_module(root, "apps/database/lib/database.ex", """
    defmodule Database do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      def insert1(tuple), do: GenServer.call(__MODULE__, {:insert, tuple})
      def match(pattern), do: GenServer.call(__MODULE__, {:match, pattern})

      def init(_opts), do: {:ok, %{}}
      def handle_call({:insert, tuple}, _from, state), do: {:reply, {:ok, tuple}, state}
      def handle_call({:match, _pattern}, _from, state), do: {:reply, [], state}
    end
    """)

    # Employee app
    write_module(root, "apps/employee/lib/employee.ex", """
    defmodule Employee do
      defstruct [:surname, :givenname, :hourly_rate, :status]

      @spec all() :: [{String.t(), t()}]
      def all, do: []

      @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
      def get(_name), do: {:error, :not_found}
    end
    """)

    # Payroll app
    write_module(root, "apps/payroll/lib/payroll/application.ex", """
    defmodule Payroll.Application do
      use Application

      def start(_type, _args) do
        children = [{Phoenix.PubSub, name: Payroll.PubSub}, {Payroll, name: Payroll}]
        Supervisor.start_link(children, strategy: :one_for_one, name: Payroll.Supervisor)
      end
    end
    """)

    write_module(root, "apps/payroll/lib/payroll.ex", """
    defmodule Payroll do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)
      def enter_hours(tuple), do: GenServer.cast(Database, {:insert, tuple})

      def init(:ok), do: {:ok, %{hours: [], employees: []}}
    end
    """)
  end

  defp create_flat_structure(root) do
    write_module(root, "lib/my_app/worker.ex", """
    defmodule MyApp.Worker do
      use GenServer

      def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
      def init(_), do: {:ok, %{}}
    end
    """)

    write_module(root, "lib/my_app/pure_logic.ex", """
    defmodule MyApp.PureLogic do
      @spec calculate(integer()) :: integer()
      def calculate(x), do: x * 2
    end
    """)

    write_module(root, "lib/my_app/data_struct.ex", """
    defmodule MyApp.DataStruct do
      defstruct [:name, :value]
    end
    """)
  end

  defp write_module(root, relative_path, content) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
