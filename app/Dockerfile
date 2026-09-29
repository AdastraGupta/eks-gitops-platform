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
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["java"]
CMD ["-jar", "/app/app.jar"]





FROM node:18 AS build
WORKDIR /app
COPY package*.json .
RUN npm install
COPY . .
RUN npm run build 

FROM node:18-alpine AS runtime
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser:appuser

COPY --from=build /app/dist          ./dist
COPY --from=build /app/node_modules  ./node_modules
COPY --from=build /app/package*.json .

EXPOSE 8000
ENTRYPOINT ["node"]
CMD ["dist/index.js"]