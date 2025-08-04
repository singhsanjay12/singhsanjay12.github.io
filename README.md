# Sanjay Singh's Blog

A Jekyll-powered blog focused on infrastructure, Kubernetes, and Zero Trust security. Live at [singh-sanjay.com](https://singh-sanjay.com).

## Developer Guide

### Prerequisites

- Ruby (2.6.0 or higher)
- Bundler gem
- Git

### Local Development Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/singhsanjay12/singhsanjay12.github.io.git
   cd singhsanjay12.github.io
   ```

2. **Install Bundler** (if not already installed)
   ```bash
   # For Ruby 2.6.x, use compatible bundler version
   sudo gem install bundler -v 2.4.22
   
   # For Ruby 3.x+
   gem install bundler
   ```

3. **Install dependencies**
   ```bash
   # If you encounter permission errors, use sudo
   sudo bundle install
   
   # Or without sudo if you have proper Ruby setup
   bundle install
   ```

4. **Run the development server**
   ```bash
   bundle exec jekyll serve
   ```

5. **View your site**
   - Open [http://127.0.0.1:4000](http://127.0.0.1:4000) in your browser
   - The site will automatically reload when you make changes

6. **Stop the server**
   - Press `Ctrl+C` in the terminal

### Development Workflow

#### Adding New Blog Posts

1. Create a new file in `_posts/` directory with the format:
   ```
   YYYY-MM-DD-your-post-title.md
   ```

2. Add front matter at the top of your post:
   ```yaml
   ---
   title: "Your Post Title"
   date: YYYY-MM-DD
   categories: [category1, category2]
   ---
   ```

3. Write your content in Markdown below the front matter

#### Customizing the Site

- **Homepage content**: Edit `index.md`
- **Site configuration**: Edit `_config.yml`
- **Custom styling**: Edit `css/override.css`
- **Post layout**: Edit `_layouts/post.html`
- **Navigation components**: Edit files in `_includes/`

#### File Structure

```
├── _config.yml          # Site configuration
├── _includes/           # Reusable components
│   ├── head.html
│   ├── navlinks.html
│   └── sharelinks.html
├── _layouts/            # Page templates
│   └── post.html
├── _posts/              # Blog posts
├── css/                 # Stylesheets
│   └── override.css
├── js/                  # JavaScript files
├── index.md             # Homepage
├── archive.md           # Blog archive page
├── Gemfile              # Ruby dependencies
└── README.md            # This file
```

### Troubleshooting

#### Permission Errors
If you encounter permission errors during `bundle install`:
```bash
sudo bundle install
```

#### Ruby Version Issues
- Ensure you're using Ruby 2.6.0 or higher: `ruby --version`
- If using system Ruby on macOS, you may need to use `sudo` for gem installations

#### Port Already in Use
If port 4000 is already in use:
```bash
bundle exec jekyll serve --port 4001
```

#### Regeneration Issues
If the site doesn't rebuild automatically:
```bash
bundle exec jekyll serve --force_polling
```

### Deployment

This site is configured for GitHub Pages with a custom domain (`singh-sanjay.com`).

#### Automatic Deployment
- Push changes to the `main` branch
- GitHub Pages will automatically build and deploy the site
- Changes appear live at [singh-sanjay.com](https://singh-sanjay.com)

#### Manual Build
To build the site locally for testing:
```bash
bundle exec jekyll build
```
Generated files will be in the `_site/` directory.

### Features

- **Responsive design** using Minima theme
- **Social media sharing** buttons on posts
- **Post navigation** with previous/next links
- **Archive page** organized by categories
- **Syntax highlighting** support
- **SEO optimization** with jekyll-seo-tag
- **RSS feed** generation

### Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes
4. Test locally with `bundle exec jekyll serve`
5. Commit your changes: `git commit -am 'Add some feature'`
6. Push to the branch: `git push origin feature-name`
7. Submit a pull request

### Support

For issues related to:
- **Jekyll**: Check [Jekyll documentation](https://jekyllrb.com/docs/)
- **Minima theme**: See [Minima documentation](https://github.com/jekyll/minima)
- **GitHub Pages**: Visit [GitHub Pages docs](https://docs.github.com/en/pages)

### License

This project is open source and available under the [MIT License](LICENSE).
