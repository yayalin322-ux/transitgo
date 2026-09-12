FROM node:22-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3 build-essential && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --omit=dev
COPY . .
ENV DB_PATH=/data/transitgo.db
VOLUME /data
EXPOSE 8787
CMD ["node", "src/index.mjs"]
