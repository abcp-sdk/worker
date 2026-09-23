# Toolchain image: JDK + Gradle, Alpine/musl.
#
# The generic `java` toolchain uses the newest Temurin feature release (26).
# The JVM language images extend `java25` (LTS) instead.
ARG BASE_IMAGE=toolchain-base:alpine-3.24
FROM ${BASE_IMAGE}
COPY cache/OpenJDK26U-jdk_x64_alpine-linux_hotspot_26.0.2.1_1.tar.gz /tmp/jdk.tar.gz
COPY cache/gradle-9.7.1-bin.zip /tmp/gradle.zip
RUN mkdir -p /opt/jdk && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk --strip-components=1 && rm /tmp/jdk.tar.gz \
 && unzip -q /tmp/gradle.zip -d /opt && rm /tmp/gradle.zip \
 && ln -s /opt/gradle-9.7.1 /opt/gradle
ENV JAVA_HOME=/opt/jdk PATH=/opt/jdk/bin:/opt/gradle/bin:$PATH
