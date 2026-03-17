FROM node:22-alpine

WORKDIR /app

COPY package.json /app/package.json
RUN npm install --omit=dev

COPY server.mjs /app/server.mjs
COPY ws-smoke.mjs /app/ws-smoke.mjs

ENV PORT=8000
EXPOSE 8000

CMD ["node", "server.mjs"]
