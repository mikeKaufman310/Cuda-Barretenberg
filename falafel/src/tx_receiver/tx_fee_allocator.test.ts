import { BridgeConfig, BridgeId } from '@aztec/barretenberg/bridge_id';
import { TxFeeResolver } from '../tx_fee_resolver';
import { TxType } from '@aztec/barretenberg/blockchain';
import { TxFeeAllocator } from '.';
import { numToUInt32BE } from '@aztec/barretenberg/serialize';
import { toBufferBE } from '@aztec/barretenberg/bigint_buffer';
import { randomBytes } from 'crypto';
import { TxDao } from '../entity/tx';
import { Tx } from '.';
import { ProofData } from '@aztec/barretenberg/client_proofs';

const bridgeConfigs: BridgeConfig[] = [
  {
    bridgeId: 1n,
    numTxs: 5,
    fee: 500000n,
    rollupFrequency: 2,
  },
  {
    bridgeId: 2n,
    numTxs: 10,
    fee: 2000000n,
    rollupFrequency: 4,
  },
];

type Mockify<T> = {
  [P in keyof T]: jest.Mock;
};

const BASE_GAS = 20000n;
const feeConstants = [10000n, 10000n, 50000n, 60000n, 0n, 50000n, 30000n];
const NON_FEE_PAYING_ASSET = 9999;

const getBridgeCost = (bridgeId: bigint) => {
  const bridgeConfig = bridgeConfigs.find(bc => bc.bridgeId === bridgeId);
  if (!bridgeConfig) {
    throw new Error(`Requested cost for invalid bridge ID: ${bridgeId.toString()}`);
  }
  return bridgeConfig.fee!;
};

const getSingleBridgeCost = (bridgeId: bigint) => {
  const bridgeConfig = bridgeConfigs.find(bc => bc.bridgeId === bridgeId);
  if (!bridgeConfig) {
    throw new Error(`Requested cost for invalid bridge ID: ${bridgeId.toString()}`);
  }
  const fee = bridgeConfig.fee!;
  const numTxs = BigInt(bridgeConfig.numTxs);
  const single = fee / numTxs;
  return fee % numTxs > 0n ? single + 1n : single;
};

const getTxGasWithBase = (txType: TxType) => feeConstants[txType] + BASE_GAS;

const txTypeToProofId = (txType: TxType) => (txType < TxType.WITHDRAW_TO_CONTRACT ? txType + 1 : txType);

const toProofData = (buf: Buffer) => {
  return new ProofData(buf);
};

const toTxDao = (tx: Tx, txType: TxType) => {
  return new TxDao({
    id: tx.proof.txId,
    proofData: tx.proof.rawProofData,
    offchainTxData: undefined,
    signature: undefined,
    nullifier1: undefined,
    nullifier2: undefined,
    dataRootsIndex: 0,
    created: new Date(),
    txType,
    excessGas: 0n, // provided later
  });
};

const mockTx = (id: number, fee: bigint, assetId: number, txType = TxType.ACCOUNT, bridgeId = 0n) =>
  ({
    id: Buffer.from([id]),
    proof: toProofData(
      Buffer.concat([
        numToUInt32BE(txTypeToProofId(txType), 32),
        randomBytes(8 * 32),
        toBufferBE(fee, 32),
        numToUInt32BE(assetId, 32),
        toBufferBE(BridgeId.fromBigInt(bridgeId).toBigInt(), 32),
        randomBytes(5 * 32),
      ]),
    ),
  } as any as Tx);

const mockDefiBridgeTx = (id: number, fee: bigint, bridgeId: bigint, assetId = 0) =>
  mockTx(id, fee, assetId, TxType.DEFI_DEPOSIT, bridgeId);

const preciselyFundedTx = (id: number, txType: TxType, assetId: number, excessGas = 0n) => {
  return mockTx(id, getTxGasWithBase(txType) + excessGas, assetId, txType);
};

describe('Tx Fee Allocator', () => {
  let feeResolver: Mockify<TxFeeResolver>;
  let txFeeAllocator: TxFeeAllocator;

  beforeEach(() => {
    jest.spyOn(console, 'log').mockImplementation(() => {});

    feeResolver = {
      getGasPaidForByFee: jest.fn().mockImplementation((assetId: number, fee: bigint) => fee),
      getTxGas: jest.fn().mockImplementation((assetId: number, txType: TxType) => {
        return getTxGasWithBase(txType);
      }),
      getBridgeTxGas: jest
        .fn()
        .mockImplementation(
          (assetId: number, bridgeId: bigint) => getSingleBridgeCost(bridgeId) + getTxGasWithBase(TxType.DEFI_DEPOSIT),
        ),
      isFeePayingAsset: jest.fn().mockImplementation((assetId: number) => assetId < 3),
    } as any;

    txFeeAllocator = new TxFeeAllocator(feeResolver as any);
  });

  it('correctly validates single payment', () => {
    const tx = preciselyFundedTx(1, TxType.TRANSFER, 0);
    const validation = txFeeAllocator.validateReceivedTxs([tx], [TxType.TRANSFER]);
    expect(validation.feePayingAsset).toEqual(0);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER));
    expect(validation.gasRequired).toEqual(getTxGasWithBase(TxType.TRANSFER));
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);
  });

  it('correctly validates multiple payments', () => {
    const txs = [preciselyFundedTx(1, TxType.TRANSFER, 0), preciselyFundedTx(2, TxType.TRANSFER, 0)];
    const validation = txFeeAllocator.validateReceivedTxs(txs, [TxType.TRANSFER, TxType.TRANSFER]);
    expect(validation.feePayingAsset).toEqual(0);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER) * 2n);
    expect(validation.gasRequired).toEqual(getTxGasWithBase(TxType.TRANSFER) * 2n);
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);
  });

  it('should throw if no fee paying assets', () => {
    const txs = [
      preciselyFundedTx(1, TxType.TRANSFER, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(2, TxType.TRANSFER, NON_FEE_PAYING_ASSET),
    ];
    expect(() => {
      txFeeAllocator.validateReceivedTxs(txs, [TxType.TRANSFER, TxType.TRANSFER]);
    }).toThrow('Transactions must have exactly 1 fee paying asset');
  });

  it('should throw if multiple fee paying assets', () => {
    const txs = [preciselyFundedTx(1, TxType.TRANSFER, 0), preciselyFundedTx(2, TxType.TRANSFER, 1)];
    expect(() => {
      txFeeAllocator.validateReceivedTxs(txs, [TxType.TRANSFER, TxType.TRANSFER]);
    }).toThrow('Transactions must have exactly 1 fee paying asset');
  });

  it('correctly determines fee paying asset', () => {
    const txs = [preciselyFundedTx(1, TxType.TRANSFER, 0), preciselyFundedTx(2, TxType.TRANSFER, NON_FEE_PAYING_ASSET)];
    const validation = txFeeAllocator.validateReceivedTxs(txs, [TxType.TRANSFER, TxType.TRANSFER]);
    expect(validation.feePayingAsset).toEqual(0);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER));
    expect(validation.gasRequired).toEqual(getTxGasWithBase(TxType.TRANSFER) * 2n);
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(false);
  });

  it('correctly detects non-paying DEFI', () => {
    const txs = [
      preciselyFundedTx(1, TxType.TRANSFER, 0),
      mockDefiBridgeTx(
        2,
        getTxGasWithBase(TxType.DEFI_DEPOSIT) + getSingleBridgeCost(bridgeConfigs[0].bridgeId),
        bridgeConfigs[0].bridgeId,
        NON_FEE_PAYING_ASSET,
      ),
    ];
    const validation = txFeeAllocator.validateReceivedTxs(txs, [TxType.TRANSFER, TxType.DEFI_DEPOSIT]);
    expect(validation.feePayingAsset).toEqual(0);
    // should only count the gas provided by the TRANSFER
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER));
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(true);
  });

  it('correctly calculates gas', () => {
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1),
      preciselyFundedTx(2, TxType.DEPOSIT, 1),
      preciselyFundedTx(3, TxType.TRANSFER, 1),
      preciselyFundedTx(4, TxType.WITHDRAW_TO_CONTRACT, 1),
      preciselyFundedTx(5, TxType.WITHDRAW_TO_WALLET, 1),
      mockDefiBridgeTx(
        6,
        getTxGasWithBase(TxType.DEFI_DEPOSIT) + getSingleBridgeCost(bridgeConfigs[0].bridgeId),
        bridgeConfigs[0].bridgeId,
        1,
      ),
    ];
    const validation = txFeeAllocator.validateReceivedTxs(txs, [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
      TxType.DEFI_DEPOSIT,
    ]);
    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId),
    );
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);
  });

  it('excludes gas from non-paying assets', () => {
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1),
      preciselyFundedTx(2, TxType.DEPOSIT, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(3, TxType.TRANSFER, 1),
      preciselyFundedTx(4, TxType.WITHDRAW_TO_CONTRACT, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(5, TxType.WITHDRAW_TO_WALLET, 1),
      mockDefiBridgeTx(
        6,
        getTxGasWithBase(TxType.DEFI_DEPOSIT) + getSingleBridgeCost(bridgeConfigs[0].bridgeId),
        bridgeConfigs[0].bridgeId,
        NON_FEE_PAYING_ASSET,
      ),
    ];
    const validation = txFeeAllocator.validateReceivedTxs(txs, [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
      TxType.DEFI_DEPOSIT,
    ]);
    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET),
    );
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(true);
  });

  it('correctly calculates gas with excess', () => {
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1),
      preciselyFundedTx(2, TxType.DEPOSIT, 1),
      mockTx(3, getTxGasWithBase(TxType.TRANSFER) + 13n, 1, TxType.TRANSFER),
      preciselyFundedTx(4, TxType.WITHDRAW_TO_CONTRACT, 1),
      mockTx(5, getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) + 5n, 1),
      mockDefiBridgeTx(
        6,
        getTxGasWithBase(TxType.DEFI_DEPOSIT) + getSingleBridgeCost(bridgeConfigs[0].bridgeId),
        bridgeConfigs[0].bridgeId,
        1,
      ),
    ];
    const validation = txFeeAllocator.validateReceivedTxs(txs, [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
      TxType.DEFI_DEPOSIT,
    ]);
    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        13n +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        5n +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId),
    );
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);
  });

  it('should not modify excess gas if none provided', () => {
    const txs = [preciselyFundedTx(1, TxType.TRANSFER, 0), preciselyFundedTx(2, TxType.TRANSFER, 0)];
    const txTypes = [TxType.TRANSFER, TxType.TRANSFER];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, 0n]);
  });

  it('should allocate gas according to provided fee if all assets are fee paying', () => {
    const excessGas = [10n, 11n, 12n, 13n, 14n];
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1, excessGas[0]),
      preciselyFundedTx(2, TxType.DEPOSIT, 1, excessGas[1]),
      preciselyFundedTx(3, TxType.TRANSFER, 1, excessGas[2]),
      preciselyFundedTx(4, TxType.WITHDRAW_TO_CONTRACT, 1, excessGas[3]),
      preciselyFundedTx(5, TxType.WITHDRAW_TO_WALLET, 1, excessGas[4]),
    ];
    const txTypes = [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
    ];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    const totalExcess = excessGas.reduce((p, n) => p + n, 0n);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        totalExcess,
    );
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    expect(txDaos.map(dao => dao.excessGas)).toEqual(excessGas);
  });

  it('should allocate gas according to provided fee if all assets are fee paying - include DEFI', () => {
    const excessGas = [10n, 11n, 12n, 13n, 14n, 15n];
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1, excessGas[0]),
      preciselyFundedTx(2, TxType.DEPOSIT, 1, excessGas[1]),
      preciselyFundedTx(3, TxType.TRANSFER, 1, excessGas[2]),
      preciselyFundedTx(4, TxType.WITHDRAW_TO_CONTRACT, 1, excessGas[3]),
      preciselyFundedTx(5, TxType.WITHDRAW_TO_WALLET, 1, excessGas[4]),
      mockDefiBridgeTx(
        6,
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
          getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
          getTxGasWithBase(TxType.DEFI_CLAIM) +
          excessGas[5],
        bridgeConfigs[0].bridgeId,
        1,
      ),
    ];
    const txTypes = [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
      TxType.DEFI_DEPOSIT,
    ];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    const totalExcess = excessGas.reduce((p, n) => p + n, 0n);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM) +
        totalExcess,
    );
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    expect(txDaos.map(dao => dao.excessGas)).toEqual(excessGas);
  });

  it('should allocate excess gas to first non-fee paying tx', () => {
    const excessGas = getTxGasWithBase(TxType.TRANSFER);
    const txs = [
      preciselyFundedTx(3, TxType.TRANSFER, 1, excessGas),
      preciselyFundedTx(4, TxType.TRANSFER, NON_FEE_PAYING_ASSET),
    ];
    const txTypes = [TxType.TRANSFER, TxType.TRANSFER];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER) + excessGas);

    expect(validation.gasRequired).toEqual(getTxGasWithBase(TxType.TRANSFER) * 2n);
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    // no excess. the additional fee on the first transfer was completely used to pay for non-fee payer
    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, 0n]);
  });

  it('should allocate excess gas to first non-fee paying tx 2', () => {
    const excessGas = getTxGasWithBase(TxType.TRANSFER) + 50n;
    const txs = [
      preciselyFundedTx(3, TxType.TRANSFER, 1, excessGas),
      preciselyFundedTx(4, TxType.TRANSFER, NON_FEE_PAYING_ASSET),
    ];
    const txTypes = [TxType.TRANSFER, TxType.TRANSFER];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER) + excessGas);

    expect(validation.gasRequired).toEqual(getTxGasWithBase(TxType.TRANSFER) * 2n);
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    // first transfer paid 50 more than needed for the second tx. the excess goes to the second transfer
    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, 50n]);
  });

  it('should allocate excess gas to first non-fee paying tx 3', () => {
    const excessGas =
      getTxGasWithBase(TxType.TRANSFER) +
      getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) * 2n +
      getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
      101n;
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1),
      preciselyFundedTx(2, TxType.DEPOSIT, 1, excessGas),
      preciselyFundedTx(3, TxType.TRANSFER, 1),
      preciselyFundedTx(4, TxType.TRANSFER, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(5, TxType.WITHDRAW_TO_CONTRACT, 1),
      preciselyFundedTx(6, TxType.WITHDRAW_TO_CONTRACT, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(7, TxType.WITHDRAW_TO_CONTRACT, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(8, TxType.WITHDRAW_TO_WALLET, 1),
      preciselyFundedTx(9, TxType.WITHDRAW_TO_WALLET, NON_FEE_PAYING_ASSET),
    ];
    const txTypes = [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
      TxType.WITHDRAW_TO_WALLET,
    ];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        excessGas,
    );

    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) * 2n +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) * 3n +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) * 2n,
    );
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    // only the 101 excess is left after tx costs have been accounted for
    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, 0n, 0n, 101n, 0n, 0n, 0n, 0n, 0n]);
  });

  it('should allocate excess gas to first non-fee paying tx 4', () => {
    const excessGas =
      getTxGasWithBase(TxType.TRANSFER) +
      getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) * 2n +
      getTxGasWithBase(TxType.WITHDRAW_TO_WALLET);
    const txs = [
      preciselyFundedTx(1, TxType.ACCOUNT, 1),
      preciselyFundedTx(2, TxType.DEPOSIT, 1, excessGas),
      preciselyFundedTx(3, TxType.TRANSFER, 1),
      preciselyFundedTx(4, TxType.TRANSFER, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(5, TxType.WITHDRAW_TO_CONTRACT, 1),
      preciselyFundedTx(6, TxType.WITHDRAW_TO_CONTRACT, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(7, TxType.WITHDRAW_TO_CONTRACT, NON_FEE_PAYING_ASSET),
      preciselyFundedTx(8, TxType.WITHDRAW_TO_WALLET, 1),
      preciselyFundedTx(9, TxType.WITHDRAW_TO_WALLET, NON_FEE_PAYING_ASSET),
    ];
    const txTypes = [
      TxType.ACCOUNT,
      TxType.DEPOSIT,
      TxType.TRANSFER,
      TxType.TRANSFER,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_CONTRACT,
      TxType.WITHDRAW_TO_WALLET,
      TxType.WITHDRAW_TO_WALLET,
    ];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) +
        excessGas,
    );
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.ACCOUNT) +
        getTxGasWithBase(TxType.DEPOSIT) +
        getTxGasWithBase(TxType.TRANSFER) * 2n +
        getTxGasWithBase(TxType.WITHDRAW_TO_CONTRACT) * 3n +
        getTxGasWithBase(TxType.WITHDRAW_TO_WALLET) * 2n,
    );
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    // no excess, tx costs have consumed all provided gas
    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n]);
  });

  it('should allocate excess gas to non-paying DEFI', () => {
    const excessGas =
      getTxGasWithBase(TxType.DEFI_DEPOSIT) +
      getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
      getTxGasWithBase(TxType.DEFI_CLAIM);
    const txs = [
      preciselyFundedTx(3, TxType.TRANSFER, 1, excessGas),
      mockDefiBridgeTx(6, 0n, bridgeConfigs[0].bridgeId, 1),
    ];
    const txTypes = [TxType.TRANSFER, TxType.DEFI_DEPOSIT];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER) + excessGas);
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(false);
    expect(validation.hasNonPayingDefi).toEqual(false);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    // no excess. the additional fee on the first transfer was completely used to pay for the DEFI
    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, 0n]);
  });

  it('should allocate excess gas to non-paying DEFI - full bridge', () => {
    const excessGas =
      getTxGasWithBase(TxType.DEFI_DEPOSIT) +
      getBridgeCost(bridgeConfigs[0].bridgeId) +
      getTxGasWithBase(TxType.DEFI_CLAIM);
    const txs = [
      preciselyFundedTx(3, TxType.TRANSFER, 1, excessGas),
      mockDefiBridgeTx(6, 0n, bridgeConfigs[0].bridgeId, NON_FEE_PAYING_ASSET),
    ];
    const txTypes = [TxType.TRANSFER, TxType.DEFI_DEPOSIT];

    // daos start off with 0 excess gas
    const txDaos = txs.map((tx, i) => {
      return toTxDao(tx, txTypes[i]);
    });

    const validation = txFeeAllocator.validateReceivedTxs(txs, txTypes);

    expect(validation.feePayingAsset).toEqual(1);
    expect(validation.gasProvided).toEqual(getTxGasWithBase(TxType.TRANSFER) + excessGas);
    // gas required includes the claim
    expect(validation.gasRequired).toEqual(
      getTxGasWithBase(TxType.TRANSFER) +
        getTxGasWithBase(TxType.DEFI_DEPOSIT) +
        getSingleBridgeCost(bridgeConfigs[0].bridgeId) +
        getTxGasWithBase(TxType.DEFI_CLAIM),
    );
    expect(validation.hasNonFeePayingAssets).toEqual(true);
    expect(validation.hasNonPayingDefi).toEqual(true);

    // no excess gas so nothing should be 'reallocated'
    txFeeAllocator.reallocateGas(txDaos, txs, txTypes, validation);

    const expectedExcess = BigInt(bridgeConfigs[0].numTxs - 1) * getSingleBridgeCost(bridgeConfigs[0].bridgeId);

    // the DEFI should have excess equal to all other bridge tx slots
    expect(txDaos.map(dao => dao.excessGas)).toEqual([0n, expectedExcess]);
  });
});
