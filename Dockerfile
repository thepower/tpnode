# Build stage 0
FROM erlang:22.3.4-slim

# Install some libs
RUN apt-get update && \
      apt-get install --no-install-recommends -y libstdc++6 openssl libtinfo5 && \
      rm -rf /var/lib/apt/lists/* 

# Set working directory
WORKDIR /opt/thepower

RUN mkdir -p /opt/thepower/db

# Copy Power_node application
COPY . .

# Set symlink
RUN ln -s /usr/bin/openssl /usr/local/bin/openssl

# Expose relevant ports
EXPOSE 49841
EXPOSE 29841

ENTRYPOINT [ "./bin/thepower" ] 

CMD ["foreground"]