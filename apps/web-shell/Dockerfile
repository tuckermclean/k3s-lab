# Tiny Go build for web-shell server
FROM golang:1.22 as build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/web-shell ./

FROM gcr.io/distroless/base-debian12:nonroot
WORKDIR /app
COPY --from=build /out/web-shell /app/web-shell
COPY static /app/static
USER nonroot
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/web-shell"]
