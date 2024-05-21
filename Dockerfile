FROM node:14

WORKDIR /app

COPY . .

EXPOSE 3000

CMD ["node", "server.js"]

HEALTHCHECK --interval=5s --timeout=1s --retries=3 CMD curl --fail http://localhost:3000 || exit 1


