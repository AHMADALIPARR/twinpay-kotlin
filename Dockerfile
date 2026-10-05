# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Ahmad Parr
#
# twinpay sealed container. Build stage fetches Temurin 21 + kotlinc and
# compiles the zero-dependency Kotlin sources; the runtime stage is JRE-only
# and serves with no outbound network needed.

FROM eclipse-temurin:21-jdk AS build
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sL -o /tmp/kotlin.zip \
      https://github.com/JetBrains/kotlin/releases/download/v2.4.20/kotlin-compiler-2.4.20.zip \
 && unzip -q /tmp/kotlin.zip -d /opt && rm /tmp/kotlin.zip
WORKDIR /app
COPY src ./src
RUN /opt/kotlinc/bin/kotlinc src/main/kotlin -include-runtime -d /app/twinpay.jar \
 && jar ufe /app/twinpay.jar twinpay.MainKt

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/twinpay.jar .
EXPOSE 8080
ENV TWINPAY_HTTP_PORT=8080 TWINPAY_HTTP_BIND=0.0.0.0
ENTRYPOINT ["java", "-jar", "twinpay.jar"]
