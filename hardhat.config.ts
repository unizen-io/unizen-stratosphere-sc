import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-etherscan';
import '@nomiclabs/hardhat-solhint';
import '@nomicfoundation/hardhat-chai-matchers';
import '@openzeppelin/hardhat-upgrades';
import '@typechain/ethers-v5';
import { config as dotenvConfig } from 'dotenv';
import 'hardhat-change-network';
import 'hardhat-deploy';
import 'hardhat-gas-reporter';
import 'hardhat-typechain';
import { resolve } from 'path';
import 'solidity-coverage';
import 'hardhat-contract-sizer';
require('hardhat-abi-exporter');
require('hardhat-contract-sizer');

dotenvConfig({ path: resolve(__dirname, './.env') });
const CHAIN_IDS = {
  hardhat: 1337,
  mainnet: 1,
  rinkeby: 4,
  bsc: 56,
  bsctest: 97,
  matic: 137,
  mumbai: 80001,
  avax: 43114,
  fantom: 250,
  arbitrum: 42161,
  optimism: 10,
  base: 8453,
};

const PRIVK = process.env.DEPLOYER_PRIVATE_KEY || '';

const config = {
  defaultNetwork: 'hardhat',
  networks: {
    test: {
      url: 'http://127.0.0.1:8545',
      timeout: 2000000000,
    },
    hardhat: {
      chainId: CHAIN_IDS.bsc,
      forking: {
        url: `https://bsc-dataseed.binance.org/`,
        blockNumber: 54025000,
      },
    },
    bsc: {
      url: 'https://bsc-dataseed.binance.org/',
      chainId: CHAIN_IDS.bsc,
      // timeout: 8000000,
      accounts: [PRIVK],
    },
    bscTest: {
      url: 'https://data-seed-prebsc-1-s2.bnbchain.org:8545',
      chainId: 97,
      timeout: 1000000000,
      accounts: [PRIVK],
    },
    matic: {
      url: process.env.MATIC_RPC || '',
      chainId: CHAIN_IDS.matic,
      timeout: 8000000,
      accounts: [PRIVK],
    },
    avax: {
      url: `https://avalanche-c-chain-rpc.publicnode.com`,
      chainId: CHAIN_IDS.avax,
      accounts: [PRIVK],
      throwOnTransactionFailures: true,
      throwOnCallFailures: true,
      allowUnlimitedContractSize: true,
      blockGasLimit: 0x1fffffffffffff,
    },
    fantom: {
      url: `https://rpc.ankr.com/fantom/`,
      chainId: CHAIN_IDS.fantom,
      accounts: [PRIVK],
      gas: 3000000,
      throwOnTransactionFailures: true,
      throwOnCallFailures: true,
      allowUnlimitedContractSize: true,
      blockGasLimit: 0x1fffffffffffff,
    },
    arbitrum: {
      url: `https://arb1.arbitrum.io/rpc`,
      chainId: CHAIN_IDS.arbitrum,
      accounts: [PRIVK],
      gasPrice: 100000000,
    },
    optimism: {
      url: 'https://optimism.blockpi.network/v1/rpc/public',
      chainId: CHAIN_IDS.optimism,
      accounts: [PRIVK],
    },
    base: {
      url: 'https://mainnet.base.org',
      chainId: CHAIN_IDS.base,
      accounts: [PRIVK],
    },
  },
  solidity: {
    compilers: [{ version: '0.8.12', settings: { optimizer: { enabled: true, runs: 10 } } }],
  },
  mocha: {
    timeout: 8000000,
  },
  gasReporter: {
    currency: 'USD',
    coinmarketcap: process.env.COINMARKETCAP_API_KEY || '',
    enabled: process.env.GAS_REPORT ? true : false,
  },
  namedAccounts: {
    deployer: {
      default: 0, // Here this will by default take the first account as deployer
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY || '',
  },
};
export default config;
