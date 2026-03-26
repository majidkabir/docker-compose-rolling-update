FROM node:20-alpine

WORKDIR /app

# Install curl for health checks
RUN apk add --no-cache curl

COPY . .

EXPOSE 3000

CMD ["node", "server.js"]

# Health check: verify the server responds
HEALTHCHECK --interval=5s --timeout=2s --retries=3 --start-period=5s \
    CMD curl -f http://localhost:3000/ || exit 1
