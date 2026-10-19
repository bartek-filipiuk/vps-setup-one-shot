# syntax=docker/dockerfile:1
FROM golang:1.25-alpine AS build
WORKDIR /src
ENV GOTOOLCHAIN=local
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /app .

# distroless: no shell, no package manager; runs as the nonroot user (uid 65532).
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
USER nonroot
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 CMD ["/app", "-healthcheck"]
ENTRYPOINT ["/app"]
