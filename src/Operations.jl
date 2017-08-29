module Operations

using Base.Random: UUID
using Base: LibGit2
using Base: Pkg

using TerminalMenus

using Pkg3: user_depot, depots
using Pkg3.Types

function find_installed(uuid::UUID, sha1::SHA1)
    for depot in depots()
        path = abspath(depot, "packages", string(uuid), string(sha1))
        ispath(path) && return path
    end
    return abspath(user_depot(), "packages", string(uuid), string(sha1))
end

function package_env_info(
    pkg::String,
    project::Dict = load_project(),
    manifest::Dict = load_manifest();
    verb::String = "choose",
)
    haskey(manifest, pkg) || return nothing
    infos = manifest[pkg]
    isempty(infos) && return nothing
    if haskey(project, "deps") && haskey(project["deps"], pkg)
        uuid = project["deps"][pkg]
        filter!(infos) do info
            haskey(info, "uuid") && info["uuid"] == uuid
        end
        length(infos) < 1 &&
            error("manifest has no stanza for $pkg/$uuid")
        length(infos) > 1 &&
            error("manifest has multiple stanzas for $pkg/$uuid")
        return first(infos)
    elseif length(infos) == 1
        return first(infos)
    else
        options = String[]
        paths = convert(Dict{String,Vector{String}}, find_registered(pkg))
        for info in infos
            uuid = info["uuid"]
            option = uuid
            if haskey(paths, uuid)
                for path in paths[uuid]
                    info′ = parse_toml(path, "package.toml")
                    option *= " – $(info′["repo"])"
                    break
                end
            else
                option *= " – (unregistred)"
            end
            push!(options, option)
        end
        menu = RadioMenu(options)
        choice = request("Which $pkg package do you want to use:", menu)
        choice == -1 && error("Package load aborted")
        return infos[choice]
    end
end

get_or_make(::Type{T}, d::Dict{K}, k::K) where {T,K} =
    haskey(d, k) ? convert(T, d[k]) : T()

function load_versions(path::String)
    toml = parse_toml(path, "versions.toml")
    Dict(VersionNumber(ver) => SHA1(info["hash-sha1"]) for (ver, info) in toml)
end

function load_package_data(f::Base.Callable, path::String, versions)
    toml = parse_toml(path, fakeit=true)
    data = Dict{VersionNumber,Dict{String,Any}}()
    for ver in versions
        ver::VersionNumber
        for (v, d) in toml, (key, value) in d
            vr = VersionRange(v)
            ver in vr || continue
            dict = get!(data, ver, Dict{String,Any}())
            haskey(dict, key) && error("$ver/$key is duplicated in $path")
            dict[key] = f(value)
        end
    end
    return data
end

load_package_data(f::Base.Callable, path::String, version::VersionNumber) =
    get(load_package_data(f, path, [version]), version, nothing)

function deps_graph(env::EnvCache, pkgs::Vector{PackageVersion})
    deps = Dict{UUID,Dict{VersionNumber,Tuple{SHA1,Dict{UUID,VersionSpec}}}}()
    uuids = [pkg.package.uuid for pkg in pkgs]
    seen = UUID[]
    while true
        unseen = setdiff(uuids, seen)
        isempty(unseen) && break
        for uuid in unseen
            push!(seen, uuid)
            deps[uuid] = valtype(deps)()
            for path in registered_paths(env, uuid)
                version_info = load_versions(path)
                versions = sort!(collect(keys(version_info)))
                dependencies = load_package_data(UUID, joinpath(path, "dependencies.toml"), versions)
                compatibility = load_package_data(VersionSpec, joinpath(path, "compatibility.toml"), versions)
                for (v, h) in version_info
                    d = get_or_make(Dict{String,UUID}, dependencies, v)
                    r = get_or_make(Dict{String,VersionSpec}, compatibility, v)
                    q = Dict(u => get_or_make(VersionSpec, r, p) for (p, u) in d)
                    VERSION in get_or_make(VersionSpec, r, "julia") || continue
                    deps[uuid][v] = (h, q)
                    for (p, u) in d
                        u in uuids || push!(uuids, u)
                    end
                end
            end
        end
        find_registered!(env, uuids)
    end
    return deps
end

"Resolve a set of versions given package version specs"
function resolve_versions(env::EnvCache, pkgs::Vector{PackageVersion})
    info("Resolving package versions")
    reqs = Dict{String,Pkg.Types.VersionSet}(string(pkg.package.uuid) => pkg.version for pkg in pkgs)
    deps = convert(Dict{String,Dict{VersionNumber,Pkg.Types.Available}}, deps_graph(env, pkgs))
    deps = Pkg.Query.prune_dependencies(reqs, deps)
    vers = Pkg.Resolve.resolve(reqs, deps)
    return convert(Dict{UUID,VersionNumber}, vers)
end

"Find names, repos and hashes for each package UUID & version"
function version_data(env::EnvCache, versions::Dict{UUID,VersionNumber})
    names = Dict{UUID,String}()
    hashes = Dict{UUID,SHA1}()
    upstreams = Dict{UUID,Vector{String}}()
    for (uuid, ver) in versions
        upstreams[uuid] = String[]
        for path in registered_paths(env, uuid)
            info = parse_toml(path, "package.toml")
            if haskey(names, uuid)
                names[uuid] == info["name"] ||
                    error("$uuid: name mismatch between registries: ",
                          "$(names[uuid]) vs. $(info["name"])")
            else
                names[uuid] = info["name"]
            end
            repo = info["repo"]
            repo in upstreams[uuid] || push!(upstreams[uuid], repo)
            vers = load_versions(path)
            if haskey(vers, ver)
                h = vers[ver]
                if haskey(hashes, uuid)
                    h == hashes[uuid] ||
                        warn("$uuid: hash mismatch for version $ver!")
                else
                    hashes[uuid] = h
                end
            end
        end
        @assert haskey(hashes, uuid)
    end
    foreach(sort!, values(upstreams))
    return names, hashes, upstreams
end

const refspecs = ["+refs/*:refs/remotes/cache/*"]

function install(env::EnvCache, uuid::UUID, name::String, hash::SHA1, urls::Vector{String})
    version_path = find_installed(uuid, hash)
    ispath(version_path) && return nothing
    repo_path = joinpath(user_depot(), "upstream", string(uuid))
    git_hash = LibGit2.GitHash(hash.bytes)
    repo = ispath(repo_path) ? LibGit2.GitRepo(repo_path) : begin
        info("Cloning [$uuid] $name")
        LibGit2.clone(urls[1], repo_path, isbare=true)
    end
    for i = 2:length(urls)
        try LibGit2.GitObject(repo, git_hash)
            break # object was found, we can stop
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
        end
        url = urls[i]
        info("Updating $name from $url")
        LibGit2.fetch(repo, remoteurl=url, refspecs=refspecs)
    end
    tree = try
        LibGit2.GitObject(repo, git_hash)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
        error("$name: git object $(string(hash)) could not be found")
    end
    tree isa LibGit2.GitTree ||
        error("$name: git object $(string(hash)) should be a tree, not $(typeof(tree))")
    mkpath(version_path)
    opts = LibGit2.CheckoutOptions(
        checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
        target_directory = Base.unsafe_convert(Cstring, version_path)
    )
    info("Installing $name at $(string(hash))")
    LibGit2.checkout_tree(repo, tree, options=opts)
    return nothing
end

function update_project(env::EnvCache, pkgs::Vector{PackageVersion})
    for pkg in pkgs
        env.project["deps"][pkg.package.name] = string(pkg.package.uuid)
    end
end

function update_manifest(env::EnvCache, uuid::UUID, name::String, hash::SHA1, version::VersionNumber)
    infos = get!(env.manifest, name, Dict{String,Any}[])
    info = nothing
    for i in infos
        UUID(i["uuid"]) == uuid || continue
        info = i
        break
    end
    if info == nothing
        info = Dict{String,Any}("uuid" => string(uuid))
        push!(infos, info)
    end
    info["version"] = string(version)
    info["hash-sha1"] = string(hash)
    delete!(info, "deps")
    for path in registered_paths(env, uuid)
        data = load_package_data(UUID, joinpath(path, "dependencies.toml"), version)
        data == nothing && continue
        info["deps"] = convert(Dict{String,String}, data)
        break
    end
    return info
end

function prune_manifest(env::EnvCache)
    keep = map(UUID, values(env.project["deps"]))
    while !isempty(keep)
        clean = true
        manifest_info(env) do name, info
            haskey(info, "uuid") && haskey(info, "deps") || return
            UUID(info["uuid"]) ∈ keep || return
            for dep::UUID in values(info["deps"])
                dep ∈ keep && continue
                push!(keep, dep)
                clean = false
            end
        end
        clean && break
    end
    filter!(env.manifest) do _, infos
        filter!(infos) do info
            haskey(info, "uuid") && UUID(info["uuid"]) ∈ keep
        end
        !isempty(infos)
    end
end

function add(env::EnvCache, pkgs::Vector{PackageVersion})
    # if a package is in the project file and
    # the manifest version in the specified version set
    # then leave the package as is at the installed version
    for (name::String, uuid::UUID) in env.project["deps"]
        info = manifest_info(env, uuid)
        info != nothing && haskey(info, "version") || continue
        version = VersionNumber(info["version"])
        for pkg in pkgs
            pkg.package.uuid == uuid && version ∈ pkg.version || continue
            pkg.version = version
        end
    end

    # resolve package versions
    versions = resolve_versions(env, pkgs)
    names, hashes, urls = version_data(env, versions)

    # clone or update repos and find or create source trees
    for (uuid, hash) in hashes
        install(env, uuid, names[uuid], hashes[uuid], urls[uuid])
    end

    # update and write project & manifest
    update_project(env, pkgs)
    for (uuid, version) in versions
        name, hash = names[uuid], hashes[uuid]
        update_manifest(env, uuid, name, hash, version)
    end
    prune_manifest(env)
    write_env(env)
end

function rm(env::EnvCache, pkgs::Vector{Package})
    # drop the indicated packages
    drop = UUID[]
    for pkg in pkgs
        info = manifest_info(env, pkg.uuid)
        if info == nothing
            str = has_name(pkg) ? pkg.name : string(pkg.uuid)
            warn("`$str` not in environemnt, ignoring")
        else
            push!(drop, pkg.uuid)
        end
    end
    # drop reverse dependencies
    while !isempty(drop)
        clean = true
        manifest_info(env) do name, info
            haskey(info, "uuid") && haskey(info, "deps") || return
            deps = map(UUID, values(info["deps"]))
            isempty(drop ∩ deps) && return
            uuid = UUID(info["uuid"])
            uuid ∉ drop || return
            push!(drop, uuid)
            clean = false
        end
        clean && break
    end
    filter!(env.project["deps"]) do _, uuid
        UUID(uuid) ∉ drop
    end
    # update project & manifest files
    prune_manifest(env)
    write_env(env)
end

function up(
    pkgs::Vector{String};
    direct::UpgradeLevel = patch,
    indirect::UpgradeLevel = major,
    registries::Bool = true,
)
    
end

# upgrage:
#  * upgrade direct deps, default to all top-levels
#  * upgrade their indirect dependencies
#  * clean up orphans

end # module
