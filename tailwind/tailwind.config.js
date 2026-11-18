const { fontFamily } = require('tailwindcss/defaultTheme');

const files = process.env.FILES_PACKAGE;

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [`${files}/**/*.html`],
  // Follow the system color scheme unless the reader picked one with the
  // switcher, which sets `data-theme` on <html>.
  darkMode: [
    'variant',
    [
      '@media (prefers-color-scheme: dark) { &:not(:where([data-theme=light], [data-theme=light] *)) }',
      '&:where([data-theme=dark], [data-theme=dark] *)'
    ]
  ],
  theme: {
    extend: {
      fontFamily: {
        mono: ['Fira Mono', 'Consolas', 'Monaco', 'Andale Mono', 'monospace'],
        sans: ['Fira Sans', 'sans-serif']
      },
      typography: (theme) => ({
        DEFAULT: {
          css: {
            'pre code': {
              fontFamily: 'Fira Mono'
            }
          }
        }
      })
    }
  },
  plugins: [require('@tailwindcss/typography')]
};

