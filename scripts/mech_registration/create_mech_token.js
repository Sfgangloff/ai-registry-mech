const { ethers } = require('hardhat')
const { LedgerSigner } = require('@anders-t/ethers-ledger')

async function main() {
	const fs = require('fs')
	const globalsFile = 'globals_gnosis.json'
	const dataFromJSON = fs.readFileSync(globalsFile, 'utf8')
	let parsedData = JSON.parse(dataFromJSON)
	const useLedger = parsedData.useLedger
	const derivationPath = parsedData.derivationPath
	const providerName = parsedData.providerName
	const gasPriceInGwei = parsedData.gasPriceInGwei
	const mechMarketplaceProxyAddress = parsedData.mechMarketplaceProxyAddress
	const mechFactoryFixedPriceTokenAddress =
		parsedData.mechFactoryFixedPriceTokenAddress
	const privateKey = parsedData.privateKey
	const payload = parsedData.payload
	const serviceId = parsedData.serviceId
	
	let networkURL = parsedData.networkURL
	if (providerName === 'polygon') {
		if (!process.env.ALCHEMY_API_KEY_MATIC) {
			console.log('set ALCHEMY_API_KEY_MATIC env variable')
		}
		networkURL += process.env.ALCHEMY_API_KEY_MATIC
	} else if (providerName === 'polygonMumbai') {
		if (!process.env.ALCHEMY_API_KEY_MUMBAI) {
			console.log('set ALCHEMY_API_KEY_MUMBAI env variable')
			return
		}
		networkURL += process.env.ALCHEMY_API_KEY_MUMBAI
	}

	const provider = new ethers.providers.JsonRpcProvider(networkURL)
	const signers = await ethers.getSigners()

	let EOA
	if (useLedger) {
		EOA = new LedgerSigner(provider, derivationPath)
	} else {
		EOA = signers[0]
	}
	EOA = new ethers.Wallet(
		privateKey,
		provider
	)
	// EOA address
	const deployer = await EOA.getAddress()
	console.log('EOA is:', deployer)

	// Get the contract instance
	const mechMarketplace = await ethers.getContractAt(
		'MechMarketplace',
		mechMarketplaceProxyAddress
	)

	// Transaction signing and execution
	console.log('15. EOA to create native mech')
	console.log(
		'You are signing the following transaction: MechMarketplaceProxy.connect(EOA).create()'
	)
	const gasPrice = ethers.utils.parseUnits(gasPriceInGwei, 'gwei')
	const result = await mechMarketplace
		.connect(EOA)
		.create(
			serviceId,
			mechFactoryFixedPriceTokenAddress,
			payload,
			{ gasLimit: 6000000 }
		)

	const tx = await result.wait()
	const nativeMech = '0x' + tx.logs[0].topics[1].slice(26)

	// Transaction details
	console.log('Contract deployment: Mech')
	console.log('Contract address:', nativeMech)
	console.log('Transaction:', result.hash)

	// Writing updated parameters back to the JSON file
	parsedData.nativeMech = nativeMech
	fs.writeFileSync(globalsFile, JSON.stringify(parsedData))
}

main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error)
		process.exit(1)
	})