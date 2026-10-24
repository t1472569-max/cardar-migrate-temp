FROM postgres:17
COPY run.sh sync.sh /
CMD ["bash","/run.sh"]
