const hre = require("hardhat");
const ethers = hre.ethers;
const fs = require('fs');

const seperator = "\t-----------------------------------------"

async function main() {

    let RevestFraxETH;

    const PROVIDERS = {
        1:'0xd2c6eB7527Ab1E188638B86F2c14bbAd5A431d78',
        31337: "0xd2c6eB7527Ab1E188638B86F2c14bbAd5A431d78",
        4:"0x21744C9A65608645E1b39a4596C39848078C2865",
        137:"0xC03bB46b3BFD42e6a2bf20aD6Fa660e4Bd3736F8",
        250:"0xe0741aE6a8A6D87A68B7b36973d8740704Fd62B9",
        43114:"0xd2c6eB7527Ab1E188638B86F2c14bbAd5A431d78"
    };

    const signers = await ethers.getSigners();
    const owner = signers[0];
    const network = await ethers.provider.getNetwork();
    const chainId = network.chainId;

    let PROVIDER_ADDRESS = PROVIDERS[chainId];

    
    console.log(seperator);
    console.log("\tDeploying FraxETH/ETH Frax Farming <> Revest Integration");

    console.log(seperator);
    console.log("\tDeploying RevestConvexFrax");
    const RevestLiquidDriverFactory = await ethers.getContractFactory("RevestConvexFrax");
    RevestFraxETH = await RevestLiquidDriverFactory.deploy(PROVIDER_ADDRESS);
    await RevestFraxETH.deployed();

    console.log(seperator);
    console.log("\tVerifying contract with Etherscan");

    await run("verify:verify", {
        address: RevestFraxETH.address,
        constructorArguments: [
            PROVIDERS[chainId],
        ],
    });
    
    console.log(seperator);
    console.log("\tRevestConvexFrax Deployed at: " + RevestFraxETH.address);
    console.log("\tDeployment successful!");

}



main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.log("Deployment Error.\n\n----------------------------------------------\n");
        console.error(error);
        process.exit(1);
    })
