# ---------------------------------------------------------------------------
# Multi-stage Dockerfile for CallType.Api
# ---------------------------------------------------------------------------
# Stage 1 (build): Restore NuGet packages, compile, and publish a
#   self-contained release build. Using SDK image only in this stage
#   keeps it out of the final image.
# Stage 2 (final): Copy the published output into the slim ASP.NET
#   runtime image. No SDK, no source code, no obj/bin artifacts.
# ---------------------------------------------------------------------------

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 8080
# The slim ASP.NET image has no curl. Configure an HTTP /health probe in
# the orchestrator instead of an always-failing in-container command.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Copy csproj first for layer caching — NuGet restore is expensive and only
# needs to re-run when dependencies change, not when source code changes.
# Build context is src/server (see docker-compose.yml), not this folder:
# CallType.Api references ../CallType.Audit, which a narrower context cannot see.
COPY ["CallType.Api/CallType.Api.csproj", "CallType.Api/"]
COPY ["CallType.Audit/CallType.Audit.csproj", "CallType.Audit/"]
RUN dotnet restore CallType.Api/CallType.Api.csproj
COPY CallType.Api/ CallType.Api/
COPY CallType.Audit/ CallType.Audit/
RUN dotnet publish CallType.Api/CallType.Api.csproj -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "CallType.Api.dll"]
