FROM node:20-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY --chown=node:node server.js .

# The official node image ships an unprivileged "node" user.
USER node

EXPOSE 3000

# Exec form so node runs as PID 1 and receives SIGTERM directly.
# The healthcheck lives in docker-compose.yaml.
CMD ["node", "server.js"]
