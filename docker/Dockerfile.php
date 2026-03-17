FROM php:8.4-fpm-alpine

# Enable opcache (built into the image, no compilation needed)
RUN docker-php-ext-enable opcache

WORKDIR /var/www/html

# Copy application source code
COPY src/ .

# Set ownership
RUN chown -R www-data:www-data /var/www/html

CMD ["php-fpm"]
