# Multi-stage build for ParseNet
# Builder stage
FROM nimlang/nim:2.2.0-alpine AS builder

WORKDIR /app

# Copy nimble file first for dependency caching
COPY parse_net.nimble .
RUN nimble install -y --depsOnly

# Copy source code and config
COPY src/ src/
COPY config.nims .

# Build release binary
RUN nimble build -d:release -y

# Runtime stage
FROM alpine:3.20

RUN apk add --no-cache pcre libgcc

# Create non-root user
RUN addgroup -g 1001 -S parsenet && \
    adduser -u 1001 -S parsenet -G parsenet

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/parse_net /app/parse_net

# Set ownership
RUN chown -R parsenet:parsenet /app

USER parsenet

EXPOSE 8080

ENV PORT=8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["/app/parse_net"]
