# --- Build stage ---
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -DskipTests

# --- Runtime stage ---
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
RUN addgroup -S spring && adduser -S spring -G spring
USER spring:spring
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java"]
CMD ["-jar", "app.jar"]



FROM node:18 AS builder
WORKDIR /app
COPY package*.json .
RUN npm install
COPY . .
RUN npm run build 

FROM node:18-alpine AS runtime
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser:appuser

COPY --from=builder /app/dist          ./dist
COPY --from=builder /app/node_modules  ./node_modules
COPY --from=builder /app/package*.json .

EXPOSE 8000
ENTRYPOINT ["node"]
CMD ["dist/index.js"]


FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json .
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine AS runtime
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/build /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
