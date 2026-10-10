# Build on the native platform and cross-compile for the target (no QEMU needed for multi-arch).
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/quote-api .

# distroless/static: no shell, no package manager, ships a nonroot user (65532).
FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/quote-api /quote-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/quote-api"]
