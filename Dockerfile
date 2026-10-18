FROM node:20-alpine
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION NODE_ENV=production
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
COPY web.js api.js ./
USER node
EXPOSE 3000 4000
CMD ["node", "web.js"]
