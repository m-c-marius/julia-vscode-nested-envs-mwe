# Git worktrees inside a workspace make dynamic indexing redo its work. See README.md.
#
#   julia mwe.jl [--worktrees 3] [--rev main] [--scenarios default,gitignored,no-env-resolution,dynamic-off] [--work DIR]
#
# Needs git and network access (General registry, symbolcache.julialang.net). Packages are
# installed into the default depot: indexing children always use it. Memory is read from /proc,
# so the memory column is Linux only.

using Printf

# Scenarios run in their own process, in an environment that has JuliaWorkspaces.
const SCENARIO_MODE = get(ARGS, 1, "") == "--scenario"
if SCENARIO_MODE
    using JuliaWorkspaces
end

const JW_URL = "https://github.com/julia-vscode/JuliaWorkspaces.jl"
const SCENARIOS = Dict(
    # what the language server runs by default
    "default" => (dynamic="DynamicIndexingOnly", resolve=true, gitignore=false),
    # `.claude/worktrees/` in `.gitignore`, as the Claude Code docs suggest
    "gitignored" => (dynamic="DynamicIndexingOnly", resolve=true, gitignore=true),
    # julia.enableWorkspaceEnvironmentResolution = false
    "no-env-resolution" => (dynamic="DynamicIndexingOnly", resolve=false, gitignore=false),
    # julia.enableDynamicIndexing = false
    "dynamic-off" => (dynamic="DynamicOff", resolve=true, gitignore=false),
)
const SCENARIO_ORDER = ["default", "gitignored", "no-env-resolution", "dynamic-off"]

julia() = `$(Base.julia_cmd()) --startup-file=no`

# ─── Scenario: runs in its own process, with JuliaWorkspaces loaded ─────────────────────────

function run_scenario(name, repo, store, nworktrees, events)
    s = SCENARIOS[name]
    snapshot, changed = Ref{Any}(nothing), Ref(0.0)
    jw = JuliaWorkspace(;
        dynamic=getfield(JuliaWorkspaces, Symbol(s.dynamic)),
        symbolcache_download=true,
        store_path=store,
        resolve_workspace_environments=s.resolve,
        status_callback=x -> (snapshot[] = x; changed[] = time()))
    scenario_phases(jw, snapshot, changed, repo, nworktrees, events)
end

# CPU seconds of all terminated and reaped child processes of this one.
function children_cpu_seconds()
    Sys.isunix() || return NaN
    ru = Ref(ntuple(_ -> Int64(0), 18))   # struct rusage, 144 bytes
    ccall(:getrusage, Cint, (Cint, Ptr{Cvoid}), -1, ru) == 0 || return NaN   # RUSAGE_CHILDREN
    t = ru[]
    usec(x) = x & 0xffffffff              # suseconds_t is 32 bit on macOS
    return t[1] + usec(t[2]) / 1e6 + t[3] + usec(t[4]) / 1e6
end

function scenario_phases(jw, snapshot, changed, repo, nworktrees, events)
    mark(event, phase, t=time()) = open(io -> println(io, t, '\t', event, '\t', phase, '\t', children_cpu_seconds()), events, "a")

    # Waits until the dynamic feature has nothing left to do, and returns when that happened: the
    # last change of its status, or now if it had nothing to do.
    function settle()
        added = time()
        sleep(2)   # lets the reactor see the files just added
        deadline = time() + 20 * 60
        while !(snapshot[] === nothing || snapshot[].indexing_done)
            time() < deadline || error("timed out waiting for the dynamic feature")
            sleep(0.25)
        end
        wait_until_ready(jw)
        return max(added, changed[])
    end

    # Opening the workspace, as the language server does for a workspace folder.
    @info "MWE phase: startup"
    mark("start", "startup")
    add_folder_from_disc!(jw, repo; ignore_io_errors=true)
    mark("ready", "startup", settle())
    sleep(5)
    mark("end", "startup")

    # One detached checkout per subagent, where Claude Code puts them. The new folders reach the
    # workspace as the language server handles a "folder created" file watcher event: walked with
    # the git ignore rules of the workspace folder (on versions that have them).
    @info "MWE phase: worktrees"
    mark("start", "worktrees")
    worktrees = [joinpath(repo, ".claude", "worktrees", "agent-" * string(rand(UInt32), base=16, pad=8)) for _ in 1:nworktrees]
    for dir in worktrees
        run(`git -C $repo worktree add -q --detach $dir HEAD`)
    end
    watcher = isdefined(JuliaWorkspaces, :GitIgnoreFilter) ? (; gitignore=GitIgnoreFilter([repo])) : (;)
    for dir in worktrees
        add_folder_from_disc!(jw, dir; ignore_io_errors=true, watcher...)
    end
    mark("ready", "worktrees", settle())
    sleep(5)
    mark("end", "worktrees")

    shutdown!(jw)
end

# ─── Setup ──────────────────────────────────────────────────────────────────────────────────

# A package with the nested environments many repositories have. `Manifest.toml` is gitignored
# and the checkout is instantiated, as a developer's checkout usually is; a new worktree is a
# checkout of tracked files only, so it has no manifests.
function make_fixture(dir)
    uuid = "5c2b7c1e-0d5a-4f0e-9b0e-6a3f1d2c4e11"
    environments = [
        "docs" => ["Documenter" => "e30172f5-a6a5-5a46-863b-614d45cd2de4"],
        "benchmark" => ["BenchmarkTools" => "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf",
                        "DataFrames" => "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"],
        "examples" => ["JSON3" => "0f8b85d8-7281-11e9-16c2-39a750bddbf1",
                       "StaticArrays" => "90137ffa-7385-5640-81b9-e52037218182"],
    ]
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), "name = \"Demo\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n")
    write(joinpath(dir, "src", "Demo.jl"), "module Demo\n\ngreet() = \"hello\"\n\nend\n")
    for (name, deps) in environments
        mkpath(joinpath(dir, name))
        project = "[deps]\n" * join(("$n = \"$u\"\n" for (n, u) in deps), "")
        # `docs/` tracks the package it documents, as such environments usually do.
        name == "docs" && (project *= "Demo = \"$uuid\"\n\n[sources]\nDemo = {path = \"..\"}\n")
        write(joinpath(dir, name, "Project.toml"), project)
        write(joinpath(dir, name, "script.jl"), "# Uses the environment next to it.\n")
    end
    write(joinpath(dir, ".gitignore"), "Manifest.toml\n")
    commit(dir, "fixture"; init=true)
    for env in ["", first.(environments)...]
        run(`$(julia()) --project=$(joinpath(dir, env)) -e 'import Pkg; Pkg.instantiate()'`)
    end
end

function commit(dir, message; init=false)
    init && run(`git -C $dir init -q -b main`)
    run(`git -C $dir add .`)
    run(`git -C $dir -c user.name=mwe -c user.email=mwe@example.invalid commit -q -m $message`)
end

function make_env(dir, rev)
    code = """
        import Pkg
        Pkg.add(url=$(repr(JW_URL)), rev=$(repr(rev)))
        Pkg.precompile()
        using JuliaWorkspaces
        # Prepare the environment indexing children run in, so no scenario pays for that.
        JuliaWorkspaces.djp_runtime(JuliaWorkspaces.default_djp_julia_exe())
        println("JuliaWorkspaces ", pkgversion(JuliaWorkspaces))
        """
    run(`$(julia()) --project=$dir -e $code`)
    return dir
end

# ─── Process-tree sampling (Linux) ──────────────────────────────────────────────────────────

function process_table()
    table = Dict{Int,Tuple{Int,String}}()   # pid => (ppid, command line)
    for entry in readdir("/proc")
        all(isdigit, entry) || continue
        try
            stat = read("/proc/$entry/stat", String)
            ppid = parse(Int, split(stat[findlast(')', stat)+2:end])[2])
            table[parse(Int, entry)] = (ppid, replace(read("/proc/$entry/cmdline", String), '\0' => ' '))
        catch   # exited while being read
        end
    end
    return table
end

function descendants(table, root)
    found = [root]
    for pid in found, (child, (ppid, _)) in table
        ppid == pid && push!(found, child)
    end
    return found
end

# PSS splits pages shared between processes (sysimage, package images), so the sum over a tree is
# what the machine pays. Summed RSS would count them once per process.
function pss_mb(pid)
    try
        for line in eachline("/proc/$pid/smaps_rollup")
            startswith(line, "Pss:") && return parse(Int, split(line)[2]) / 1024
        end
    catch
    end
    return 0.0
end

# Samples (time, total PSS in MB) every half second until `cmd` exits.
function run_sampled(cmd)
    proc = run(cmd; wait=false)
    samples = Tuple{Float64,Float64}[]
    while process_running(proc)
        if Sys.islinux()
            table = process_table()
            push!(samples, (time(), sum(pss_mb, descendants(table, getpid(proc)))))
        end
        sleep(0.5)
    end
    success(proc) || error("scenario failed: $cmd")
    return samples
end

# ─── Driver ─────────────────────────────────────────────────────────────────────────────────

function summarize(scenario, events_file, log, samples)
    events = Dict{Tuple{String,String},Tuple{Float64,Float64}}()
    for line in eachline(events_file)
        t, event, phase, cpu = split(line, '\t')
        events[(event, phase)] = (parse(Float64, t), parse(Float64, cpu))
    end
    # Spawn and skip lines are attributed to the phase they are logged in.
    spawned, skipped = Dict{String,Int}(), Dict{String,Int}()
    phase = ""
    for line in eachline(log)
        (m = match(r"MWE phase: (\w+)", line)) !== nothing && (phase = m[1])
        occursin("Spawning indexing child process", line) && (spawned[phase] = get(spawned, phase, 0) + 1)
        occursin(r"dynamic indexing is disabled|local indexing is disabled", line) && (skipped[phase] = get(skipped, phase, 0) + 1)
    end
    return map(["startup", "worktrees"]) do phase
        (t0, cpu0), (tready, _), (t1, cpu1) = events[("start", phase)], events[("ready", phase)], events[("end", phase)]
        window = [mb for (t, mb) in samples if t0 <= t <= t1]
        (; scenario, phase, children=get(spawned, phase, 0), skipped=get(skipped, phase, 0),
           cpu=cpu1 - cpu0, seconds=tready - t0, peak=isempty(window) ? NaN : maximum(window) / 1024)
    end
end

function main(args)
    opts = Dict("worktrees" => "3", "rev" => "main", "scenarios" => join(SCENARIO_ORDER, ","), "work" => "")
    for (key, value) in Iterators.partition(args, 2)
        k = lstrip(key, '-')
        haskey(opts, k) || error("unknown option $key")
        opts[k] = value
    end
    scenarios = split(opts["scenarios"], ',')
    all(in(keys(SCENARIOS)), scenarios) || error("--scenarios takes $(join(SCENARIO_ORDER, ", "))")
    work = isempty(opts["work"]) ? mktempdir(; prefix="jw-worktrees-mwe-", cleanup=false) : mkpath(abspath(opts["work"]))
    println("Julia $VERSION, work directory $work")

    ref = try readchomp(`git ls-remote $JW_URL $(opts["rev"])`) catch; "" end
    println("JuliaWorkspaces ", opts["rev"], isempty(ref) ? "" : " ($(split(ref)[1]))")
    env = make_env(joinpath(work, "env"), opts["rev"])
    fixture = joinpath(work, "fixture")
    make_fixture(fixture)

    rows = []
    for scenario in scenarios
        println("\n== $scenario")
        dir = mkpath(joinpath(work, scenario))
        repo = joinpath(dir, "repo")
        cp(fixture, repo)
        if SCENARIOS[scenario].gitignore
            write(joinpath(repo, ".gitignore"), "Manifest.toml\n.claude/worktrees/\n")
            commit(repo, "ignore worktrees")
        end
        events, log = joinpath(dir, "events.tsv"), joinpath(dir, "log.txt")
        cmd = `$(julia()) --project=$env $(@__FILE__) --scenario $scenario $repo $(mkpath(joinpath(dir, "store"))) $(opts["worktrees"]) $events`
        samples = open(io -> run_sampled(pipeline(cmd; stdout=io, stderr=io)), log, "w")
        append!(rows, summarize(scenario, events, log, samples))
    end

    println("\nJulia $VERSION, $(opts["worktrees"]) worktrees\n")
    println("| scenario | phase | indexing children | skipped, needed a child | children CPU (s) | time to idle (s) | peak memory (GB) |")
    println("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for r in rows
        @printf("| %s | %s | %d | %d | %.0f | %.0f | %.1f |\n", r.scenario, r.phase, r.children, r.skipped, r.cpu, r.seconds, r.peak)
    end
    println("\nlogs: $work")
end

if SCENARIO_MODE
    run_scenario(ARGS[2], ARGS[3], ARGS[4], parse(Int, ARGS[5]), ARGS[6])
else
    main(ARGS)
end
