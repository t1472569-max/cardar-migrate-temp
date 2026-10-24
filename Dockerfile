FROM postgres:17
COPY run.sh /run.sh
CMD ["bash","/run.sh"]
