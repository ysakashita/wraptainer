FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

COPY pom.xml .
RUN mvn -B dependency:go-offline -q

COPY src/ ./src/
RUN mvn -B clean package -DskipTests -q

# ---- Runtime stage ----
FROM tomcat:10.1-jdk21-temurin

ENV CATALINA_HOME=/usr/local/tomcat

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf "$CATALINA_HOME"/webapps/* \
    && groupadd -r tomcat \
    && useradd -r -g tomcat -d "$CATALINA_HOME" tomcat \
    && chown -R tomcat:tomcat "$CATALINA_HOME"

COPY --from=build --chown=tomcat:tomcat /build/target/simple-shopping-site-1.0.0-SNAPSHOT.war "$CATALINA_HOME"/webapps/shop.war

USER tomcat

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/shop/actuator/health || exit 1

CMD ["catalina.sh", "run"]
