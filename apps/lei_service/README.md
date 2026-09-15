# lowendinsight-get

![bus_factor](priv/static/images/lei_bus_128.png)

Supply chain security analysis API for git repositories.

![default_elixir_ci](https://github.com/kitplummer/lowendinsight-get/workflows/default_elixir_ci/badge.svg)

## Features

- **URL Analysis**: Analyze single or multiple git repository URLs
- **SBOM Analysis**: Parse CycloneDX/SPDX SBOMs and analyze all dependencies
- **GitHub Trending**: Analyze trending repositories across programming languages
- **Caching**: Redis-backed cache with configurable TTL
- **Cache Modes**: `blocking`, `async`, `stale` for flexible cache-miss handling
- **Air-Gap Support**: Export/import cache for disconnected environments
- **Job Queue**: Oban-based persistent job queue with PostgreSQL

## Current Version

**Use v0.9.3** (v0.9.2 had CI/Docker networking issues, v0.9.1 had template path issue, v0.9.0 had container build issue)

```bash
docker pull ghcr.io/kitplummer/lowendinsight-get:0.9.3
```

## Documentation

- **[Interactive API Docs](http://localhost:4000/doc)** - Swagger UI for exploring and testing the API
- **[API Reference](docs/API.md)** - Complete REST API documentation
- **[Operations Guide](docs/OPERATIONS.md)** - Deployment, configuration, and maintenance

## Quick Start

See `lowendinsight`'s README for more details on the underlying
functionality: https://github.com/kitplummer/lowendinsight

The workflow for this API is asynchronous.  The POST to `/v1/analyze` will return immediately, providing you with a `uuid` for the job.

You then can do a GET to `/v1/analyze/:uuid` (with your newly minted ID) to retrieve the results.  The analyzer job will change `state` from "incomplete" to "complete" when the analysis is done.

Unfortunately some git repositories are just huge, and will take time to download - even a single branch.  The service does employ a basic cache, and can be configured with a TTL.  The default is set to sweep out reports at 30 days.

## Configuration

Look at `config/config.exs` or if you're building your own container
`rel/config/prod.exs` (which is used as the container's prod config :)) for how to set the governance par levels, and the cache TTL.

The configuration items are also explained at
https://github.com/kitplummer/lowendinsight in more detail.

## Note: For Windows, avoid using single quotes in commands.  Use double quotes instead and escape nested quotes i.e. use \"

## Run

### Development

You can run with `mix` but you'll have to ensure a provided Redis service is available and the correct configuration is referenced in `config/config.exs`.  Then you run: `mix run --no-halt`.

Don't forget to get fetch the dependencies:

```bash
mix deps.get && mix run --no-halt
```

### Production

Well, if you're at this point I'd recommend using the Docker Compose or Kubernetes deployments.  Configuration for both are found in the repo.

The `docker-compose.yml` will spin up a Redis db and the LowEndInsight containers, exposing the services.  You can simply run `docker-compose up` to launch things.

Within the `k8s` subdirectory you'll find configuration files for both Redis (single node configuration) and LowEndInsight.  For example:

```bash
➜  kubectl apply -f k8s/redis-master-deployment.yaml
deployment.apps/redis-master created
➜  kubectl apply -f k8s/redis-master-service.yaml
service/redis-master created
➜  kubectl apply -f k8s/deployment.yaml
deployment.apps/lei-get created
➜  kubectl apply -f k8s/service.yaml
service/lei-get created
➜  kubectl get all
NAME                                READY   STATUS    RESTARTS   AGE
pod/lei-get-7f4bd755c9-7m6fz        1/1     Running   0          23s
pod/redis-master-7db7f6579f-x97df   1/1     Running   0          37s


NAME                   TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
service/kubernetes     ClusterIP      10.96.0.1       <none>        443/TCP          17d
service/lei-get        LoadBalancer   10.96.15.135    <pending>     4000:32224/TCP   17s
service/redis-master   ClusterIP      10.96.247.238   <none>        6379/TCP         33s


NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/lei-get        1/1     1            1           23s
deployment.apps/redis-master   1/1     1            1           37s

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/lei-get-7f4bd755c9        1         1         1       23s
replicaset.apps/redis-master-7db7f6579f   1         1         1       37s
```

### Heroku

It's also possible to run this in Heroku using the Elixir buildpack.  The Redis configuration requires the Heroku Redis addon which will set the REDIS_URL environment variable.  The `procfile` at the root of the repo is used by the buildpack to run the app.  While this isn't a Phoenix app I used this URL as a guide:

https://hexdocs.pm/phoenix/heroku.html

And this one for the Redis setup:

https://devcenter.heroku.com/articles/heroku-redis#provisioning-the-add-on

## REST API

Full API documentation: **[docs/API.md](docs/API.md)**

### Core Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/v1/analyze` | Analyze git repository URLs |
| `GET` | `/v1/analyze/:uuid` | Get analysis results by job ID |
| `POST` | `/v1/analyze/sbom` | Analyze SBOM (CycloneDX/SPDX) |

### API Documentation

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/doc` | Swagger UI - interactive API explorer |
| `GET` | `/openapi.json` | OpenAPI 3.0 specification (JSON) |

### Cache Management

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/v1/cache/stats` | Get cache statistics |
| `GET` | `/v1/cache/export` | Export cache for air-gapped deployment |
| `POST` | `/v1/cache/import` | Import pre-warmed cache |

### GitHub Trending

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/gh_trending` | List available languages |
| `GET` | `/gh_trending/:language` | View trending report for language |
| `POST` | `/v1/gh_trending/process` | Trigger trending analysis (async) |

### Example: Analyze URLs

```bash
curl -X POST 'http://localhost:4000/v1/analyze' \
  -H 'Authorization: Bearer $TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"urls":["https://github.com/owner/repo"], "cache_mode": "blocking"}'
```

### Example: Analyze SBOM

```bash
curl -X POST 'http://localhost:4000/v1/analyze/sbom' \
  -H 'Authorization: Bearer $TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"sbom": {"bomFormat":"CycloneDX","components":[...]}, "cache_mode": "async"}'
```

### Example: Export/Import Cache (Air-Gap)

```bash
# Export from connected environment
curl -H 'Authorization: Bearer $TOKEN' \
  https://lei.example.com/v1/cache/export > cache.json

# Import to air-gapped environment
curl -X POST 'http://lei-local:4000/v1/cache/import' \
  -H 'Authorization: Bearer $TOKEN' \
  -H 'Content-Type: application/json' \
  -d @cache.json
```

## License

See LICENSE

```
# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.
```

## Contributing

Thanks for considering, we need your contributions to help this project come to fruition.

Here are some important resources:

  * Bugs? [Issues](https://github.com/kitplummer/lowendinsight-get/issues/new) is where to report them

### Style

The repo includes auto-formatting, please run `mix format` to format to
the standard style prescribed by the Elixir project:

https://hexdocs.pm/mix/Mix.Tasks.Format.html

https://github.com/christopheradams/elixir_style_guide

Code docs for functions are expected.  Examples are a bonus:

https://hexdocs.pm/elixir/writing-documentation.html

### Testing

Required. Please write ExUnit test for new code you create.

Use `mix test --cover` to verify that you're maintaining coverage.


### Github Actions

Just getting this built-out.  But the bitbucket-pipeline config is still
here too.

### Submitting changes

Please send a [Pull Request](https://github.com/kitplummer/lowendinsight-get/pull-requests/) with a clear list of what you've done and why. Please follow Elixir coding conventions (above in Style) and make sure all of your commits are atomic (one feature per commit).

Always write a clear log message for your commits. One-line messages are fine for small changes, but bigger changes should look like this:

    $ git commit -m "A brief summary of the commit
    >
    > A paragraph describing what changed and its impact."
