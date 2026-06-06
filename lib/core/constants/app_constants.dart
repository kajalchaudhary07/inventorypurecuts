class AppConstants {
  static const String appName = 'PureCuts';
  static const String appTagline = 'Pro Salon Products, Fast Delivery';
  static const String logoPath =
      'assets/icons/purecutslogo-removebg-preview.png';

  // Dummy categories
  static const List<Map<String, dynamic>> categories = [
    {'name': 'Hair Care', 'icon': 'assets/icons/hair-cutting.png'},
    {'name': 'Skin Care', 'icon': 'assets/icons/skincare.png'},
    {'name': 'Color', 'icon': 'assets/icons/hair-dye.png'},
    {'name': 'Tools', 'icon': 'assets/icons/makeup-brushes.png'},
    {'name': 'Accessories', 'icon': 'assets/icons/Accessories.png'},
    {'name': 'Disposables', 'icon': 'assets/icons/Disposables.png'},
    {'name': 'Furnitures', 'icon': 'assets/icons/Furnitures.png'},
    {'name': 'Machineries', 'icon': 'assets/icons/Machineries.png'},
  ];

  static const List<Map<String, dynamic>> subCategories = [
    {'name': 'Conditioner', 'parentCategory': 'Hair Care'},
    {'name': 'Hair Spa', 'parentCategory': 'Hair Care'},
    {'name': 'Hair Color', 'parentCategory': 'Hair Care'},
    {'name': 'Shampoo', 'parentCategory': 'Hair Care'},
    {'name': 'Serum', 'parentCategory': 'Hair Care'},
    {'name': 'Neutralizing Cream', 'parentCategory': 'Hair Care'},
    {'name': 'Hair Masque', 'parentCategory': 'Hair Care'},
    {'name': 'Hair Texture', 'parentCategory': 'Hair Care'},
    {'name': 'Hair Creams & Masks', 'parentCategory': 'Hair Care'},
    {'name': 'Sunscreen', 'parentCategory': 'Skin Care'},
    {'name': 'Face Wash', 'parentCategory': 'Skin Care'},
    {'name': 'Facial Scrub', 'parentCategory': 'Skin Care'},
    {'name': 'Facial De-Tan', 'parentCategory': 'Skin Care'},
    {'name': 'Facial Gel', 'parentCategory': 'Skin Care'},
    {'name': 'Facial Kit', 'parentCategory': 'Skin Care'},
    {'name': 'Facepack', 'parentCategory': 'Skin Care'},
    {'name': 'Facial Cream', 'parentCategory': 'Skin Care'},
    {'name': 'Facial Mask', 'parentCategory': 'Skin Care'},
    {'name': 'Permanent Color', 'parentCategory': 'Color'},
    {'name': 'Fashion Shades', 'parentCategory': 'Color'},
    {'name': 'Developers', 'parentCategory': 'Color'},
    {'name': 'Bleach', 'parentCategory': 'Color'},
    {'name': 'Brushes & Bowls', 'parentCategory': 'Color'},
    {'name': 'Scissors', 'parentCategory': 'Tools'},
    {'name': 'Clippers', 'parentCategory': 'Tools'},
    {'name': 'Brushes', 'parentCategory': 'Tools'},
    {'name': 'Mirrors', 'parentCategory': 'Tools'},
    {'name': 'Spray Bottle', 'parentCategory': 'Accessories'},
    {'name': 'Comb & Brushes', 'parentCategory': 'Accessories'},
    {'name': 'Hair Cutting Scissor', 'parentCategory': 'Accessories'},
    {'name': 'Blades', 'parentCategory': 'Accessories'},
    {'name': 'Gloves', 'parentCategory': 'Disposables'},
    {'name': 'Aprons', 'parentCategory': 'Disposables'},
    {'name': 'Tissues', 'parentCategory': 'Disposables'},
    {'name': 'Wax Strips', 'parentCategory': 'Disposables'},
    {'name': 'Disposable Towels', 'parentCategory': 'Disposables'},
    {'name': 'Hair Wash Chair', 'parentCategory': 'Furnitures'},
    {'name': 'Trolley', 'parentCategory': 'Furnitures'},
    {'name': 'Steamers', 'parentCategory': 'Furnitures'},
    {'name': 'Facial & Spa Bed', 'parentCategory': 'Furnitures'},
    {'name': 'Styling Chair', 'parentCategory': 'Furnitures'},
    {'name': 'Straightener', 'parentCategory': 'Machineries'},
    {'name': 'Trimmers', 'parentCategory': 'Machineries'},
    {'name': 'Pedicure', 'parentCategory': 'Machineries'},
    {'name': 'Hair Dryer', 'parentCategory': 'Machineries'},
    {'name': 'Wax Heater', 'parentCategory': 'Machineries'},
  ];

  static const List<Map<String, dynamic>> subSubCategories = [
    {
      'name': 'Developers & Peroxides',
      'parentCategory': 'Hair Care',
      'parentSubCategory': 'Hair Color',
    },
    {
      'name': 'Hair color gel',
      'parentCategory': 'Hair Care',
      'parentSubCategory': 'Hair Color',
    },
    {
      'name': 'Hair colour cream',
      'parentCategory': 'Hair Care',
      'parentSubCategory': 'Hair Color',
    },
    {
      'name': 'Hair dye',
      'parentCategory': 'Hair Care',
      'parentSubCategory': 'Hair Color',
    },
  ];

  // Dummy orders
  static const List<Map<String, dynamic>> orders = [
    {
      'id': 'ORD-1001',
      'date': '5 Mar 2026',
      'items': 3,
      'total': 2450,
      'status': 'Delivered',
    },
    {
      'id': 'ORD-998',
      'date': '28 Feb 2026',
      'items': 1,
      'total': 850,
      'status': 'Delivered',
    },
    {
      'id': 'ORD-982',
      'date': '20 Feb 2026',
      'items': 5,
      'total': 6100,
      'status': 'Delivered',
    },
  ];
}
