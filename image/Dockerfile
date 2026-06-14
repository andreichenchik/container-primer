FROM docker.io/library/node:22-slim
WORKDIR /app
COPY package.json ./
RUN npm install
COPY server.ts ./
