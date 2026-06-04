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
# Health check so Docker/compose/orchestrators can probe liveness without
# an external tool. The /health endpoint returns 200 when the API is ready.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Copy csproj first for layer caching — NuGet restore is expensive and only
# needs to re-run when dependencies change, not when source code changes.
COPY ["CallType.Api.csproj", "."]
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "CallType.Api.dll"]
