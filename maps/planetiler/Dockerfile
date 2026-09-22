FROM eclipse-temurin:21-jdk AS build
ARG PLANETILER_VERSION=0.10.2
WORKDIR /opt/sunoh
ADD https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar planetiler.jar
COPY Sunoh.java .
RUN chmod 644 planetiler.jar && javac -proc:none -sourcepath /tmp/empty -cp planetiler.jar Sunoh.java

FROM eclipse-temurin:21-jre
WORKDIR /work
COPY --from=build /opt/sunoh /opt/sunoh
ENTRYPOINT ["java", "-cp", "/opt/sunoh/planetiler.jar:/opt/sunoh", "Sunoh"]
