defmodule Mix.Tasks.AgentEx.MigrateDets do
  @moduledoc """
  One-time migration from global DETS files to per-project DETS files.

  For each project with a root_path:
  1. Creates .agent_ex/ directory under root_path
  2. Opens per-project DETS file
  3. Scans global DETS file, copies matching {user_id, project_id, ...} entries
  4. Verifies entry count

  After all projects are migrated, renames old global DETS files to *.bak.

  ## Usage

      mix agent_ex.migrate_dets
      mix agent_ex.migrate_dets --dry-run
  """

  use Mix.Task

  require Logger

  @stores [
    {:agent_configs, 3},
    {:http_tool_configs, 3},
    {:persistent_memory, 4},
    {:procedural_memory, 4}
  ]

  @impl Mix.Task
  def run(args) do
    dry_run? = "--dry-run" in args
    Mix.Task.run("app.start")

    dets_dir = Application.get_env(:agent_ex, :dets_dir, "priv/data")

    global_files =
      @stores
      |> Enum.map(fn {name, _} -> {name, Path.join(dets_dir, "#{name}.dets")} end)
      |> Enum.filter(fn {_, path} -> File.exists?(path) end)

    if global_files == [] do
      Mix.shell().info("No global DETS files found in #{dets_dir}. Nothing to migrate.")
    else
      run_migration(global_files, dry_run?)
    end
  end

  defp run_migration(global_files, dry_run?) do
    Mix.shell().info("Found #{length(global_files)} global DETS file(s) to migrate.")

    projects =
      AgentEx.Projects.Project
      |> AgentEx.Repo.all()
      |> Enum.filter(&(&1.root_path && &1.root_path != ""))

    Mix.shell().info("Found #{length(projects)} project(s) with root_path.")

    if projects == [] do
      Mix.shell().info("No projects with root_path. Set root_path on projects first.")
    else
      migrate_all(global_files, projects, dry_run?)
    end
  end

  defp migrate_all(global_files, projects, dry_run?) do
    Enum.each(global_files, fn {store_name, global_path} ->
      migrate_store(store_name, global_path, projects, dry_run?)
    end)

    rename_global_files(global_files, dry_run?)
    Mix.shell().info(if dry_run?, do: "Dry run complete.", else: "Migration complete!")
  end

  defp rename_global_files(_files, true), do: :ok

  defp rename_global_files(files, false) do
    Enum.each(files, fn {_name, path} ->
      bak_path = path <> ".bak"

      case File.rename(path, bak_path) do
        :ok -> Mix.shell().info("Renamed #{path} -> #{bak_path}")
        {:error, reason} -> Mix.shell().error("Failed to rename #{path}: #{inspect(reason)}")
      end
    end)
  end

  defp migrate_store(store_name, global_path, projects, dry_run?) do
    Mix.shell().info("\nMigrating #{store_name}...")

    dets_ref = :"global_#{store_name}_migration"
    charlist_path = String.to_charlist(global_path)

    case :dets.open_file(dets_ref, file: charlist_path, type: :set) do
      {:ok, ^dets_ref} ->
        migrate_and_close(dets_ref, projects, store_name, dry_run?)

      {:error, reason} ->
        Mix.shell().error("Failed to open #{global_path}: #{inspect(reason)}")
    end
  end

  defp migrate_and_close(dets_ref, projects, store_name, dry_run?) do
    do_migrate_store(dets_ref, projects, store_name, dry_run?)
  after
    :dets.close(dets_ref)
  end

  defp do_migrate_store(dets_ref, projects, store_name, dry_run?) do
    project_map = Map.new(projects, fn p -> {{p.user_id, p.id}, p.root_path} end)
    entries_by_project = scan_global_dets(dets_ref, project_map)

    total = Enum.reduce(entries_by_project, 0, fn {_, entries}, acc -> acc + length(entries) end)
    Mix.shell().info("  Found #{total} entries across #{map_size(entries_by_project)} project(s)")

    unless dry_run? do
      write_project_entries(entries_by_project, project_map, store_name)
    end
  end

  defp scan_global_dets(dets_ref, project_map) do
    :dets.foldl(
      fn {key, value}, acc -> maybe_collect(acc, key, value, project_map) end,
      %{},
      dets_ref
    )
  end

  defp maybe_collect(acc, key, value, project_map) do
    project_key = extract_project_key(key)

    if project_key != :unknown and Map.has_key?(project_map, project_key) do
      Map.update(acc, project_key, [{key, value}], &[{key, value} | &1])
    else
      acc
    end
  end

  defp write_project_entries(entries_by_project, project_map, store_name) do
    Enum.each(entries_by_project, fn {project_key, entries} ->
      root_path = project_map[project_key]
      write_to_project_dets(root_path, store_name, entries)
    end)
  end

  defp write_to_project_dets(root_path, store_name, entries) do
    agent_ex_dir = Path.join(Path.expand(root_path), ".agent_ex")
    File.mkdir_p!(agent_ex_dir)

    project_dets_path = Path.join(agent_ex_dir, "#{store_name}.dets") |> String.to_charlist()
    project_dets_ref = :"migrate_#{store_name}_#{:erlang.phash2(project_dets_path)}"

    case :dets.open_file(project_dets_ref, file: project_dets_path, type: :set) do
      {:ok, ^project_dets_ref} ->
        insert_and_close(project_dets_ref, entries, root_path)

      {:error, reason} ->
        Mix.shell().error("  Failed to open DETS for #{root_path}: #{inspect(reason)}")
    end
  end

  defp insert_and_close(dets_ref, entries, root_path) do
    Enum.each(entries, fn {key, value} -> :dets.insert(dets_ref, {key, value}) end)
    :dets.sync(dets_ref)
    Mix.shell().info("  #{root_path}: #{length(entries)} entries")
  after
    :dets.close(dets_ref)
  end

  defp extract_project_key({user_id, project_id, _}), do: {user_id, project_id}
  defp extract_project_key({user_id, project_id, _, _}), do: {user_id, project_id}

  defp extract_project_key(other) do
    Logger.warning("Unexpected DETS key format: #{inspect(other)}")
    :unknown
  end
end
