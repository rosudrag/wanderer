module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  roots: ['<rootDir>'],
  moduleDirectories: ['node_modules', 'js'],
  moduleNameMapper: {
    '\.(scss|css)$': 'identity-obj-proxy', // Mock SCSS/CSS files (incl. 3rd-party like reactflow/dist/style.css);
    // must come before the "@/" alias below - moduleNameMapper takes the FIRST matching key, and
    // an unordered swap here silently stops proxying every "@/...scss" import (this repo's `@/`
    // alias is used far more than relative scss imports).
    '^@/(.*)$': '<rootDir>/js/$1',
  },
  transform: {
    '^.+\.(ts|tsx)$': 'ts-jest',
    '^.+\.(js|jsx)$': 'babel-jest', // Add babel-jest for JS/JSX files if needed
  },
};
